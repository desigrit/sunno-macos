import Foundation
import Speech
import AVFoundation
import CoreMedia

// Private framed pipe, never a network listener. No microphone access and no audio files.
// Only the explicit prepare command may install system model assets.
struct Request: Decodable {
    let op: String
    let samples: Int?
    let final: Bool?
}

struct ServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let next = FileHandle.standardInput.readData(ofLength: count - data.count)
        if next.isEmpty { return nil }
        data.append(next)
    }
    return data
}

func readRequest() throws -> (Request, Data)? {
    guard let header = readExactly(4) else { return nil }
    let count = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
    guard count > 0, count <= 65536, let data = readExactly(count) else {
        throw ServiceError(message: "Invalid request header.")
    }
    let request = try JSONDecoder().decode(Request.self, from: data)
    let samples = request.samples ?? 0
    guard samples >= 0, samples <= 16000 * 30, let audio = readExactly(samples * 4) else {
        throw ServiceError(message: "Invalid audio frame.")
    }
    return (request, audio)
}

func reply(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    var length = UInt32(data.count).littleEndian
    var packet = Data(bytes: &length, count: 4)
    packet.append(data)
    FileHandle.standardOutput.write(packet)
}

@available(macOS 26.0, *)
@MainActor
final class NativeSpeech {
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!
    private var destinationFormat: AVAudioFormat?
    private var generation = 0
    private var failed: String?
    private struct Segment {
        let range: CMTimeRange
        let text: String
    }
    private var segments: [Segment] = []

    private func transcriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw ServiceError(message: "Apple Speech is unavailable on this Mac. Choose a Whisper model.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw ServiceError(message: "Apple Speech does not support English on this Mac. Choose a Whisper model.")
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: [.volatileResults], attributeOptions: [])
    }

    func handle(_ request: Request, audio: Data) async throws -> [String: Any] {
        switch request.op {
        case "status", "prepare":
            let module = try await transcriber()
            if request.op == "prepare" {
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await installation.downloadAndInstall()
                }
            }
            let installed = await AssetInventory.status(forModules: [module]) == .installed
            return ["ok": true, "available": installed, "supported": true]
        case "begin":
            await reset()
            let module = try await transcriber()
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw ServiceError(message: "Apple Speech needs its English model. Select it again to retry setup.")
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
                  let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw ServiceError(message: "Apple Speech could not prepare its audio format.")
            }
            self.converter = converter
            destinationFormat = format
            let analyzer = SpeechAnalyzer(modules: [module],
                options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            self.analyzer = analyzer
            let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
            continuation = pair.continuation
            let token = generation
            resultsTask = Task { [weak self] in
                do {
                    for try await result in module.results {
                        guard let self, self.generation == token else { return }
                        // Revisions replace overlapping audio ranges, not the newest line.
                        self.segments.removeAll {
                            CMTimeCompare($0.range.start, result.range.start) == 0 ||
                            CMTimeRangeGetIntersection($0.range, otherRange: result.range).duration.seconds > 0
                        }
                        self.segments.append(Segment(range: result.range, text: String(result.text.characters)))
                        self.segments.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
                    }
                } catch {
                    if let self, self.generation == token {
                        self.failed = "Apple Speech stopped processing this phrase."
                    }
                }
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: pair.stream)
            return ["ok": true]
        case "push":
            guard let analyzer, let converter, let format = destinationFormat, let continuation else {
                throw ServiceError(message: "Apple Speech has no active phrase.")
            }
            if let failed { throw ServiceError(message: failed) }
            let count = audio.count / 4
            if count > 0 {
                let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count))!
                input.frameLength = AVAudioFrameCount(count)
                _ = audio.withUnsafeBytes { bytes in
                    memcpy(input.floatChannelData![0], bytes.baseAddress!, audio.count)
                }
                let capacity = AVAudioFrameCount(ceil(Double(count) * format.sampleRate / 16000) + 64)
                let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
                var consumed = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    if consumed { state.pointee = .noDataNow; return nil }
                    consumed = true
                    state.pointee = .haveData
                    return input
                }
                if status == .error { throw error ?? ServiceError(message: "Audio conversion failed.") as NSError }
                if output.frameLength > 0 {
                    if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                        throw ServiceError(message: "Apple Speech fell behind. Retrying with the next phrase.")
                    }
                }
            }
            if request.final == true {
                // Flush the converter's retained samples, then finish the async input.
                let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                var error: NSError?
                _ = converter.convert(to: tail, error: &error) { _, state in
                    state.pointee = .endOfStream
                    return nil
                }
                if tail.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: tail)) }
                continuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await resultsTask?.value
            } else {
                // Recognition runs independently; never wait for a word before feeding more audio.
                await Task.yield()
            }
            if let failed { throw ServiceError(message: failed) }
            return ["ok": true, "text": segments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)]
        case "reset":
            await reset()
            return ["ok": true]
        default:
            throw ServiceError(message: "Unknown speech command.")
        }
    }

    func reset() async {
        generation += 1
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        continuation = nil
        converter = nil
        destinationFormat = nil
        segments = []
        failed = nil
    }
}

@main
struct SpeechService {
    static func main() async {
        guard #available(macOS 26.0, *) else {
            reply(["ok": false, "error": "Apple Speech requires macOS 26 or later. Choose a Whisper model."])
            return
        }
        let service = NativeSpeech()
        while true {
            do {
                // Blocking stdin must not occupy the actor receiving asynchronous captions.
                guard let (request, audio) = try await Task.detached(operation: readRequest).value else { break }
                do { reply(try await service.handle(request, audio: audio)) }
                catch { reply(["ok": false, "error": error.localizedDescription]) }
            } catch {
                reply(["ok": false, "error": "The speech service received an invalid request."])
                break
            }
        }
        await service.reset()
    }
}
