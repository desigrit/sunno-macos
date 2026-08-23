import Foundation
import AVFoundation
import ScreenCaptureKit
import Network

/// System audio capture, so what the Mac is playing can be captioned.
///
/// There is no WASAPI loopback on macOS. `loopback.py` is Windows in full, and `pyaudiowpatch`
/// publishes no macOS wheel, so nothing on the Python side survives the crossing. This is the
/// replacement, and `docs/MACOS-PORT.md` argues at length for exactly this shape: build the
/// seam, make ScreenCaptureKit the path that must work, and leave room for a Core Audio process
/// tap on 14.4 and later as an enhancement.
///
/// ScreenCaptureKit rather than the tap, for now, because it works two macOS versions further
/// back, it is known to be allowed in the App Sandbox, and it does not block on a DTS answer
/// nobody outside Apple can give. The cost is the wrong noun on the permission prompt, which
/// `SystemAudioPermission` exists to defuse before the system asks.
///
/// **Why a socket rather than a callback.** The engine is still Python and takes its audio from
/// its own device inside `make_stream()`. Rather than teach the whole pipeline a new source, the
/// capture writes the same thing `MicrophoneStream` yields — mono float32 at 16 kHz — down a
/// loopback socket, and the backend reads it as one more stream implementation. When the engine
/// becomes native this class keeps its front half and loses its back half.
@MainActor
final class SystemAudioCapture: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    /// The port the engine is told to connect to. Ephemeral rather than fixed: a hardcoded one
    /// is a collision waiting for the first user who runs two copies.
    private(set) var port: UInt16?

    private var stream: SCStream?
    private var listener: NWListener?
    private var connection: NWConnection?
    private let output = AudioOutput()

    /// Starts the listener and the capture, and resolves once the engine has something to
    /// connect to. Throws with a sentence a person can act on rather than an OSStatus.
    func start() async throws -> UInt16 {
        stop()

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Resuming a continuation twice is a fatal error, not a warning, and the state
            // handler is called repeatedly and from the listener's own queue. A plain captured
            // `var` would be a data race on the one flag standing between a normal failure and
            // a crash, so the claim is made under a lock.
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                Task { @MainActor in
                    self?.connection = connection
                    self?.output.attach(connection)
                }
            }
            listener.start(queue: .main)
        }

        try await startStream()

        self.port = port
        status = .running
        return port
    }

    func stop() {
        output.attach(nil)
        if let stream {
            // Fire and forget: the app may be quitting, and an await here would be a hang on
            // the path where the framework is already tearing down.
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        port = nil
        status = .idle
    }

    private func startStream() async throws {
        // A display is required to build a filter even though no picture is wanted. Excluding
        // this app's own audio matters more than it looks: without it the captions Sunno speaks
        // through a screen reader would be fed back in and captioned again.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.message("No display was available to capture system audio from.")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // The video side is unwanted but a stream still produces frames, so make them as cheap
        // as the API allows and throw them away. One pixel is refused; this is the floor that
        // is accepted, and at one frame every two seconds it costs nothing measurable.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "sunno.audio"))
        // Added and discarded. Whether an audio-only SCStream is legal is listed as unverified
        // in docs/MACOS-PORT.md; taking the screen output and dropping every frame is the
        // answer that works either way, and it costs one 2x2 buffer every two seconds.
        try stream.addStreamOutput(output, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "sunno.screen"))
        try await stream.startCapture()
        self.stream = stream
    }

    enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}

/// One-shot claim, so exactly one caller may resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// The stream callback, off the main actor because ScreenCaptureKit delivers on its own queue.
///
/// Converts to the one format the engine accepts and writes it straight out. `MicrophoneStream`
/// and `LoopbackStream` both promise "mono float32 frames at SAMPLE_RATE", and this is a third
/// implementation of the same promise, so everything above it is indifferent to which is in use.
private final class AudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {

    private let lock = NSLock()
    private var connection: NWConnection?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    func attach(_ connection: NWConnection?) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = convert(sampleBuffer) else { return }
        send(samples)
    }

    /// 48 kHz stereo to 16 kHz mono, through `AVAudioConverter` rather than by hand.
    ///
    /// Dividing by three and taking every third sample would be simpler and wrong: decimating
    /// without a low-pass first folds everything above 8 kHz back down into the speech band as
    /// aliasing, which a speech model hears as noise it will happily transcribe words out of.
    /// The converter does the filtering and the downmix together.
    private func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = sampleBuffer.formatDescription,
              let asbd = description.audioStreamBasicDescription
        else { return nil }

        var streamDescription = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &streamDescription)
        else { return nil }

        lock.lock()
        if converter == nil || outputFormat == nil {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false) else {
                lock.unlock()
                return nil
            }
            outputFormat = target
            converter = AVAudioConverter(from: inputFormat, to: target)
        }
        let converter = self.converter
        let target = self.outputFormat
        lock.unlock()

        guard let converter, let target else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        input.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: input.mutableAudioBufferList)
        guard status == noErr else { return nil }

        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / inputFormat.sampleRate) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else { return nil }

        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    private func send(_ samples: [Float]) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { return }

        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
