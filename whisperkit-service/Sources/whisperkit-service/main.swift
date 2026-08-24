import Foundation
import WhisperKit
import CoreML

// A decode service, spoken to over stdin and stdout.
//
// Why a separate process at all. The speech pipeline is Python: `pipeline.py` carries the
// two-pass discipline and the endpointing, `speaker.py` the online matching, `config.py` every
// tuned constant. None of that wants rewriting to change which chip does the arithmetic. So the
// decode step alone moves to Swift, where Core ML can reach the Neural Engine and the GPU, and
// the rest stays where it is proven.
//
// Why pipes rather than a socket. The system audio path already taught this: a listener is a
// port to bind, a lifetime to manage and, if you get it wrong, an open door on the network. A
// pipe has none of those. The service dies when its parent closes stdin, which is exactly the
// lifetime wanted, and there is nothing for anyone else to connect to.
//
// Framing is a little-endian uint32 length in front of a JSON header, then the audio bytes the
// header declares. Replies are a length and a JSON body. Audio is mono float32 at 16 kHz, which
// is what the pipeline already holds.

// MARK: - Wire

struct Request: Decodable {
    let op: String
    var model: String?
    /// Where weights live. WhisperKit defaults to ~/Documents/huggingface, which puts several
    /// gigabytes in the folder a person keeps their own files in; the caller passes the app's
    /// data directory instead.
    var downloadBase: String?
    var samples: Int?
    var language: String?
    var wordTimestamps: Bool?
    var temperature: Float?
    /// The hallucination suppression from config.py. Without these Whisper decodes silence and
    /// noise into invented sentences and keeps going until it hits the token limit: two seconds
    /// of noise took 110 seconds on large-v3 before they were passed through, which presented
    /// as the app hanging on "Loading the model" during warmup.
    var noSpeechThreshold: Float?
    var logProbThreshold: Float?
    var compressionRatioThreshold: Float?

    enum CodingKeys: String, CodingKey {
        case op, model, samples, language, temperature
        case wordTimestamps = "word_timestamps"
        case downloadBase = "download_base"
        case noSpeechThreshold = "no_speech_threshold"
        case logProbThreshold = "log_prob_threshold"
        case compressionRatioThreshold = "compression_ratio_threshold"
    }
}

struct WordOut: Encodable {
    let word: String
    let probability: Float
    let start: Float
    let end: Float
}

struct Reply: Encodable {
    var ok: Bool
    var error: String?
    var text: String?
    /// The average token log-probability, which is what the clarity score is derived from.
    /// WhisperKit exposes it directly, so `asr.py`'s mapping needs no re-derivation.
    var avgLogprob: Float?
    var words: [WordOut]?
    var decodeMs: Double?
    var model: String?
    var computeUnits: String?
    /// Set on the frames sent while a download runs. The caller keeps reading until a frame
    /// arrives without it, which is the terminal one.
    var progress: Double?
    var available: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, error, text, words, model, progress, available
        case avgLogprob = "avg_logprob"
        case decodeMs = "decode_ms"
        case computeUnits = "compute_units"
    }
}

// MARK: - Framed pipe IO

let input = FileHandle.standardInput
let output = FileHandle.standardOutput

/// Reads exactly `count` bytes or returns nil at end of stream. `read` on a pipe returns what
/// happens to be buffered, so a single call is not a frame.
func readExactly(_ count: Int) -> Data? {
    guard count > 0 else { return Data() }
    var buffer = Data()
    buffer.reserveCapacity(count)
    while buffer.count < count {
        let chunk = input.readData(ofLength: count - buffer.count)
        if chunk.isEmpty { return nil }
        buffer.append(chunk)
    }
    return buffer
}

func readUInt32() -> Int? {
    guard let data = readExactly(4) else { return nil }
    return Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
}

func send(_ reply: Reply) {
    guard let body = try? JSONEncoder().encode(reply) else { return }
    var length = UInt32(body.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(body)
    output.write(frame)
}

// MARK: - Service

/// Held across requests. Loading a model is the expensive part, and the pipeline decodes an
/// utterance every few seconds.
///
/// Top-level variables are already main-actor isolated and cannot be annotated, so it is the
/// functions touching them that carry the marking. Without it the mutations are a data race the
/// Swift 6 language mode rejects, and this is a single-threaded request loop where pinning it
/// to one actor costs nothing.
var whisper: WhisperKit?
var loadedModel: String?

func describe(_ units: MLComputeUnits) -> String {
    switch units {
    case .cpuOnly: return "cpu"
    case .cpuAndGPU: return "cpu+gpu"
    case .all: return "cpu+gpu+ane"
    case .cpuAndNeuralEngine: return "cpu+ane"
    @unknown default: return "unknown"
    }
}

@MainActor
/// The folder WhisperKit keeps weights in, and the name it gives a variant inside it.
func modelFolder(base: URL, variant: String) -> URL {
    base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)")
}

func downloadBaseURL(_ request: Request) -> URL? {
    guard let path = request.downloadBase else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

@MainActor
func load(_ model: String, base: URL?) async throws {
    // The defaults already spread the work across the chip: the mel and encoder go to the GPU
    // and the text decoder to the Neural Engine. That is the whole point of this service, so
    // they are left alone rather than pinned to something narrower.
    let compute = ModelComputeOptions()
    let config = WhisperKitConfig(model: model, downloadBase: base, computeOptions: compute)
    whisper = try await WhisperKit(config)
    loadedModel = model
}

@MainActor
func handle(_ request: Request, audio: [Float]) async -> Reply {
    switch request.op {
    case "available":
        // Asked before the first-run screen decides whether to offer a download. The Core ML
        // weights are a different artifact from the CTranslate2 ones, so the answer the rest of
        // the app already has does not apply here.
        guard let model = request.model, let base = downloadBaseURL(request) else {
            return Reply(ok: false, error: "available needs a model and a download base")
        }
        let folder = modelFolder(base: base, variant: model)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        return Reply(ok: true, model: model, available: !(contents ?? []).isEmpty)

    case "prepare":
        guard let model = request.model else {
            return Reply(ok: false, error: "prepare needs a model")
        }
        do {
            // Progress is reported as it arrives, and the caller reads frames until one has no
            // progress on it. Without this the app sits on "Loading the model" for as long as
            // several gigabytes take, which is indistinguishable from being hung.
            _ = try await WhisperKit.download(
                variant: model,
                downloadBase: downloadBaseURL(request),
                progressCallback: { progress in
                    send(Reply(ok: true, model: model, progress: progress.fractionCompleted))
                }
            )
            return Reply(ok: true, model: model)
        } catch {
            return Reply(ok: false, error: "could not download \(model): \(error)")
        }

    case "load":
        guard let model = request.model else {
            return Reply(ok: false, error: "load needs a model")
        }
        do {
            try await load(model, base: downloadBaseURL(request))
            return Reply(ok: true, model: model,
                         computeUnits: describe(ModelComputeOptions().textDecoderCompute))
        } catch {
            return Reply(ok: false, error: "could not load \(model): \(error)")
        }

    case "transcribe":
        guard let whisper else {
            return Reply(ok: false, error: "no model loaded")
        }
        // Special tokens and timestamp markers are stripped here rather than by the caller.
        // Without this the text arrives as "<|startoftranscript|><|en|><|transcribe|><|0.00|>
        // The measurement microphone...", and a caption is not the place to discover that.
        var options = DecodingOptions(
            language: request.language ?? "en",
            temperature: request.temperature ?? 0
        )
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.wordTimestamps = request.wordTimestamps ?? false
        // Same three guards faster-whisper is given, from the same constants.
        options.noSpeechThreshold = request.noSpeechThreshold
        options.logProbThreshold = request.logProbThreshold
        options.compressionRatioThreshold = request.compressionRatioThreshold
        let started = Date()
        do {
            let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
            let segments = results.flatMap(\.segments)
            let text = segments.map(\.text).joined()

            // Averaged over segments, which is what faster-whisper reports per segment and what
            // asr.py already averages when a decode spans more than one.
            let logprob = segments.isEmpty
                ? nil
                : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)

            let words = segments.compactMap(\.words).flatMap { $0 }.map {
                WordOut(word: $0.word, probability: $0.probability, start: $0.start, end: $0.end)
            }

            return Reply(ok: true, text: text, avgLogprob: logprob,
                         words: words.isEmpty ? nil : words,
                         decodeMs: Date().timeIntervalSince(started) * 1000,
                         model: loadedModel)
        } catch {
            return Reply(ok: false, error: "decode failed: \(error)")
        }

    default:
        return Reply(ok: false, error: "unknown op \(request.op)")
    }
}

// MARK: - Loop

while true {
    guard let headerLength = readUInt32(),
          let headerData = readExactly(headerLength),
          let request = try? JSONDecoder().decode(Request.self, from: headerData)
    else { break }   // stdin closed: the parent is gone, and so is the reason to exist

    var audio: [Float] = []
    if let samples = request.samples, samples > 0 {
        guard let raw = readExactly(samples * 4) else { break }
        audio = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    let reply = await handle(request, audio: audio)
    send(reply)
}
