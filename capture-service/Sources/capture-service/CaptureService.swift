import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

// One disposable process owns one capture source. stdout is private framed IPC,
// not diagnostics. No device name or audio sample reaches the application log.
private struct Target: Codable {
    var kind: String = "microphone"
    var endpointID: String?
    var name: String?
    var index: Int?
    var followDefault: Bool = false

    enum CodingKeys: String, CodingKey {
        case kind, name, index
        case endpointID = "endpoint_id"
        case followDefault = "follow_default"
    }

    var wire: [String: Any] {
        ["kind": kind, "endpoint_id": endpointID as Any? ?? NSNull(),
         "name": name as Any? ?? NSNull(), "index": index as Any? ?? NSNull(),
         "follow_default": followDefault]
    }
}

private struct Failure: Error {
    let code: String
    let message: String
    var retryable = true
}

private let wireLock = NSLock()
private func send(_ message: [String: Any]) {
    wireLock.lock()
    defer { wireLock.unlock() }
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { exit(1) }
    data.append(10)
    do { try FileHandle.standardOutput.write(contentsOf: data) }
    catch { exit(0) }
}

private func fail(_ error: Error) -> Never {
    let failure = error as? Failure ?? Failure(
        code: "capture_failed", message: "Sunno could not open this input. It will try again.")
    send(["type": "error", "code": failure.code, "message": failure.message,
          "retryable": failure.retryable])
    exit(1)
}

private func checked(_ status: OSStatus) throws {
    guard status == noErr else {
        throw Failure(code: "device_unavailable",
                      message: "This input is temporarily unavailable. Sunno will reconnect.")
    }
}

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

private func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector)
    throws -> String {
    var property = address(selector)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    try checked(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
    guard let value else { throw Failure(code: "device_unavailable", message: "This input is unavailable.") }
    return value as String
}

private func deviceIDs() throws -> [AudioDeviceID] {
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &property, 0, nil, &size))
    var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    try values.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                               &property, 0, nil, &size, base))
    }
    return values
}

private func defaultInput() -> AudioDeviceID {
    var property = address(kAudioHardwarePropertyDefaultInputDevice)
    var value = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                  &property, 0, nil, &size, &value)
    return value
}

private func inputChannels(_ device: AudioDeviceID) throws -> Int {
    var property = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    try checked(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size))
    let memory = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size),
                                                 alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try checked(AudioObjectGetPropertyData(device, &property, 0, nil, &size, memory))
    let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func devices() throws -> [[String: Any]] {
    let preferred = defaultInput()
    var result: [[String: Any]] = []
    for device in try deviceIDs() {
        // An endpoint can disappear halfway through enumeration. Keep the others.
        guard let channels = try? inputChannels(device), channels > 0,
              let uid = try? stringProperty(device, kAudioDevicePropertyDeviceUID),
              let name = try? stringProperty(device, kAudioObjectPropertyName) else { continue }
        result.append(["index": Int(device), "endpoint_id": uid, "name": name,
                       "channels": channels, "hostapi": "Core Audio", "loopback": false,
                       "is_default_input": device == preferred, "is_default_output": false])
    }
    result.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    // ScreenCaptureKit captures app audio across this Mac, not a particular speaker.
    result.append(["index": -1, "endpoint_id": "system-audio", "name": "System audio (this Mac)",
                   "channels": 2, "hostapi": "ScreenCaptureKit", "loopback": true,
                   "is_default_input": false, "is_default_output": true])
    return result
}

private func resolve(_ request: Target) throws -> Target {
    guard ["microphone", "loopback"].contains(request.kind) else {
        throw Failure(code: "capture_protocol", message: "Choose a microphone or system audio input.", retryable: false)
    }
    let available = try devices().filter { ($0["loopback"] as? Bool ?? false) == (request.kind == "loopback") }
    let matches = available.filter { device in
        if request.followDefault {
            return device[request.kind == "loopback" ? "is_default_output" : "is_default_input"] as? Bool == true
        }
        if let uid = request.endpointID { return device["endpoint_id"] as? String == uid }
        // Never reinterpret an old PortAudio index as a new Core Audio device ID.
        return request.name != nil && device["name"] as? String == request.name
    }
    guard matches.count == 1, let found = matches.first else {
        throw Failure(code: matches.count > 1 ? "device_ambiguous" : "device_unavailable",
                      message: matches.count > 1 ? "Choose the input again to identify the correct device."
                          : "The selected input is not available. Sunno will reconnect when it returns.",
                      retryable: matches.count <= 1)
    }
    var target = request
    target.endpointID = found["endpoint_id"] as? String
    target.name = found["name"] as? String
    target.index = found["index"] as? Int
    return target
}

private final class Frames {
    let target: Target
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private var pending: [Float] = []
    private(set) var lastCallback: TimeInterval?
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var ready = false
    private let emitProtocol: Bool
    private(set) var emittedFrames = 0
    private(set) var converterRebuilds = 0
    // All conversion, heartbeat and protocol writes run on this one queue.
    let queue = DispatchQueue(label: "sunno.capture.frames")

    init(_ target: Target, emitProtocol: Bool = true) {
        self.target = target
        self.emitProtocol = emitProtocol
    }

    func heartbeat() { lastCallback = ProcessInfo.processInfo.systemUptime }

    func push(_ buffer: AVAudioPCMBuffer) throws {
        heartbeat()
        guard buffer.frameLength > 0 else { return }
        if inputFormat != buffer.format {
            converterRebuilds += 1
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            // Do not join partial frames from different route formats.
            pending.removeAll(keepingCapacity: true)
        }
        guard let converter else {
            throw Failure(code: "unsupported_format", message: "This input uses an unsupported audio format.",
                          retryable: false)
        }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil {
            throw Failure(code: "capture_format_changed", message: "The audio format changed. Sunno is reconnecting.")
        }
        guard let channel = output.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        while pending.count >= 512 {
            emit(Array(pending.prefix(512)))
            pending.removeFirst(512)
        }
    }

    func tick(systemAudio: Bool, started: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastCallback ?? started) < 3 else {
            fail(Failure(code: "capture_stalled", message: "The audio input stopped responding. Sunno is reconnecting."))
        }
        // Silence is healthy only after ScreenCaptureKit has proved the stream alive.
        if systemAudio, lastCallback != nil, now - lastFrame >= 512.0 / 16_000 {
            emit([Float](repeating: 0, count: 512))
        }
    }

    private func emit(_ samples: [Float]) {
        guard samples.allSatisfy({ $0.isFinite }) else {
            fail(Failure(code: "capture_protocol", message: "The audio connection was interrupted. Sunno will reconnect."))
        }
        emittedFrames += 1
        if !emitProtocol { lastFrame = ProcessInfo.processInfo.systemUptime; return }
        if !ready {
            ready = true
            send(["type": "ready", "target": target.wire])
        }
        let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        send(["type": "audio", "data": bytes.base64EncodedString()])
        lastFrame = ProcessInfo.processInfo.systemUptime
    }
}

private final class Microphone {
    private var audioQueue: AudioQueueRef?
    private let frames: Frames
    private var format: AudioStreamBasicDescription

    init(_ target: Target, frames: Frames) throws {
        self.frames = frames
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if authorization == .denied || authorization == .restricted {
            throw Failure(code: "capture_denied", message: "Allow Sunno in Privacy & Security > Microphone, then try again.",
                          retryable: false)
        }
        let device = AudioDeviceID(target.index ?? 0)
        var property = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)
        try checked(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &rate))
        let channels = try inputChannels(device)
        guard rate >= 8_000, rate <= 384_000, channels > 0, channels <= 32 else {
            throw Failure(code: "unsupported_format", message: "This input uses an unsupported audio format.",
                          retryable: false)
        }
        format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        try checked(AudioQueueNewInput(&format, { context, queue, buffer, _, _, _ in
            guard let context else { return }
            let owner = Unmanaged<Microphone>.fromOpaque(context).takeUnretainedValue()
            let data = Data(bytes: buffer.pointee.mAudioData, count: Int(buffer.pointee.mAudioDataByteSize))
            _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            owner.frames.queue.async {
                var description = owner.format
                guard let format = AVAudioFormat(streamDescription: &description),
                      let pcm = AVAudioPCMBuffer(pcmFormat: format,
                          frameCapacity: AVAudioFrameCount(data.count / Int(description.mBytesPerFrame))) else { return }
                pcm.frameLength = pcm.frameCapacity
                data.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        memcpy(pcm.mutableAudioBufferList.pointee.mBuffers.mData, base, data.count)
                    }
                }
                do { try owner.frames.push(pcm) } catch { fail(error) }
            }
        }, Unmanaged.passUnretained(self).toOpaque(), nil, nil, 0, &audioQueue))
        guard let audioQueue else { throw Failure(code: "capture_failed", message: "The microphone could not start.") }
        // The queue binds to the UID, not an index that can move after hot-plug.
        var uid = (target.endpointID ?? "") as CFString
        try checked(AudioQueueSetProperty(audioQueue, kAudioQueueProperty_CurrentDevice,
                                         &uid, UInt32(MemoryLayout<CFString>.size)))
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            let bytes = UInt32(max(512, Int(rate * .016))) * format.mBytesPerFrame
            try checked(AudioQueueAllocateBuffer(audioQueue, bytes, &buffer))
            if let buffer { try checked(AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)) }
        }
        try checked(AudioQueueStart(audioQueue, nil))
    }

    deinit {
        if let audioQueue { AudioQueueDispose(audioQueue, true) }
    }
}

private final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private let frames: Frames
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    init(_ frames: Frames) { self.frames = frames }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw Failure(code: "capture_denied",
                message: "Allow Sunno in Privacy & Security > Screen & System Audio Recording, then reopen it.",
                retryable: false)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw Failure(code: "device_unavailable", message: "No display is available for system audio. Sunno will retry.")
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == "com.desigrit.sunno" }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: frames.queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames.queue)
        self.stream = stream
        self.configuration = config
        try await stream.startCapture()
    }

    func checkAlive() async throws {
        guard let stream, let configuration else { return }
        // A static desktop may produce no screen or audio callbacks. An acknowledged
        // framework operation distinguishes healthy silence from a wedged capture.
        try await stream.updateConfiguration(configuration)
        frames.queue.async { self.frames.heartbeat() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Disconnect immediately rather than manufacture silence over a dead stream.
        fail(Failure(code: "capture_stalled", message: "System audio was interrupted. Sunno is reconnecting."))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        frames.heartbeat()
        guard type == .audio, let description = buffer.formatDescription,
              let asbd = description.audioStreamBasicDescription else { return }
        var streamDescription = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(count),
                                                         into: pcm.mutableAudioBufferList) == noErr else { return }
        do { try frames.push(pcm) } catch { fail(error) }
    }
}

// This watcher keeps reading after a stop, so EOF can still exit a native call
// that hangs during shutdown. The supervisor also enforces a bounded kill.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
private let stopFlag = StopFlag()

private func watchParent() {
    DispatchQueue.global().async {
        while readLine() != nil { stopFlag.stop() }
        exit(0)
    }
}

@main
private enum Main {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--list") {
                send(["devices": try devices()])
                return
            }
            if CommandLine.arguments.contains("--self-test") {
                let frames = Frames(Target(kind: "microphone", name: "Synthetic input"), emitProtocol: false)
                for rate in [48_000.0, 44_100.0, 96_000.0] {
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                              channels: 2, interleaved: false)!
                    let count = AVAudioFrameCount(rate * .12)
                    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
                    pcm.frameLength = count
                    for channel in 0..<2 {
                        pcm.floatChannelData![channel].initialize(repeating: .25, count: Int(count))
                    }
                    let before = frames.emittedFrames
                    try frames.push(pcm)
                    guard frames.emittedFrames > before else {
                        throw Failure(code: "capture_format_changed", message: "Synthetic resampling check failed.")
                    }
                }
                guard frames.converterRebuilds == 3 else {
                    throw Failure(code: "capture_format_changed", message: "Format-change check failed.")
                }
                send(["type": "self_test", "checks": 3, "frames": frames.emittedFrames])
                return
            }
            guard CommandLine.arguments.count > 1,
                  let json = CommandLine.arguments[1].data(using: .utf8) else {
                throw Failure(code: "capture_protocol", message: "An input selection is required.", retryable: false)
            }
            let target = try resolve(JSONDecoder().decode(Target.self, from: json))
            watchParent()
            if CommandLine.arguments.contains("--probe") {
                send(["type": "ready", "target": target.wire, "probe": true])
                return
            }
            let frames = Frames(target)
            let system = target.kind == "loopback"
            let microphone = system ? nil : try Microphone(target, frames: frames)
            let capture = system ? SystemAudio(frames) : nil
            if let capture { try await capture.start() }
            let timer = DispatchSource.makeTimerSource(queue: frames.queue)
            let started = ProcessInfo.processInfo.systemUptime
            timer.schedule(deadline: .now(), repeating: .milliseconds(32))
            timer.setEventHandler { frames.tick(systemAudio: system, started: started) }
            timer.resume()
            // Retain all native resources until stdin EOF or supervisor termination.
            var nextProbe = ProcessInfo.processInfo.systemUptime + 1
            while !stopFlag.isStopped {
                withExtendedLifetime((microphone, capture, timer)) { }
                try await Task.sleep(nanoseconds: 25_000_000)
                if let capture, ProcessInfo.processInfo.systemUptime >= nextProbe {
                    try await capture.checkAlive()
                    nextProbe = ProcessInfo.processInfo.systemUptime + 1
                }
            }
        } catch { fail(error) }
    }
}
