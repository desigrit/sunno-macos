import Foundation

/// Everything the backend can put on the socket.
///
/// Deliberately one struct with optional fields rather than an enum with associated values.
/// An enum reads better in Swift, but this is a wire format shared with two other clients
/// that are changed by a different person on a different day, and the failure modes are not
/// symmetrical: a decoder that throws on an unrecognised event takes the captions down, and
/// a decoder that ignores one keeps working. Someone relying on this to follow a conversation
/// should not lose the transcript because a field was added upstream.
///
/// The field list is pinned by `tests/test_protocol_contract.py`, which reads the backend's
/// own source and fails when the two drift. Change anything here without running it and the
/// first symptom is a caption that never arrives.
struct BackendEvent: Decodable {

    /// The discriminator. `unknown` exists so a newer backend cannot break an older client.
    enum Kind: String, Decodable {
        case status
        case partial
        case final
        case discard
        case speechStart = "speech_start"
        case level
        case roster
        case speakerMerged = "speaker_merged"
        case speakerDeleted = "speaker_deleted"
        case recording
        case modelRequired = "model_required"
        case modelCatalog = "model_catalog"
        case downloadStarted = "download_started"
        case downloadProgress = "download_progress"
        case downloadComplete = "download_complete"
        case downloadFailed = "download_failed"
        case error
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    let kind: Kind

    // status
    let state: String?
    let running: Bool?
    let device: String?

    // partial / final / discard / speech_start
    let id: Int?
    let text: String?
    let speakerId: Int?
    let speaker: String?
    /// Null on the streaming engines, which expose no comparable score. Absent rather than
    /// invented, and the UI must treat it as absent rather than defaulting it to zero.
    let clarity: Int?
    let latencyMs: Double?
    let durationS: Double?
    let startedAt: Double?
    let words: [Word]?

    // level
    let rms: Double?
    let db: Double?
    let speechProb: Double?
    let speaking: Bool?

    // roster
    let speakers: [Speaker]?

    // recording
    /// Length of audio written, not wall-clock time since the button was pressed. The two
    /// differ whenever capture stops and starts inside one recording — a pause, a swapped
    /// microphone — and the audio length is the one that matches the file that comes out.
    let elapsedS: Double?
    /// The folder being written to. Handed straight back as `resume` when the engine is
    /// restarted for a new microphone or model, so the recording continues into the same
    /// file instead of the restart quietly ending it and beginning another.
    let folder: String?
    let name: String?
    let lines: Int?

    // speaker_merged / speaker_deleted
    /// `from` is a Swift keyword, so the wire name is aliased in CodingKeys below.
    let mergedFrom: Int?
    let mergedInto: Int?
    let label: String?

    // model_required / model_catalog
    let requested: String?
    let current: String?
    let catalog: [CatalogEntry]?

    // download_*
    let model: String?
    let downloaded: Int?
    let total: Int?
    let percent: Double?

    // error
    let message: String?
    /// `mic_denied`, `mic_unavailable` or `capture_failed` when the UI can offer a specific
    /// fix. Absent when it cannot, in which case say less rather than showing raw diagnostics.
    let code: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case kind = "type"
        case state, running, device, id, text
        case speakerId = "speaker_id"
        case speaker, clarity
        case latencyMs = "latency_ms"
        case durationS = "duration_s"
        case startedAt = "started_at"
        case words, rms, db
        case speechProb = "speech_prob"
        case speaking, speakers
        case elapsedS = "elapsed_s"
        case folder, name, lines
        case mergedFrom = "from"
        case mergedInto = "into"
        case label, requested, current, catalog, model, downloaded, total, percent
        case message, code, detail
    }

    struct Word: Decodable {
        let t: String
        let p: Double
    }

    struct Speaker: Decodable {
        let id: Int
        let label: String
        let named: Bool
        let isSelf: Bool

        enum CodingKeys: String, CodingKey {
            case id, label, named
            case isSelf = "is_self"
        }
    }

    struct CatalogEntry: Decodable, Identifiable {
        let id: String
        let name: String
        let detail: String
        let approxMb: Int
        let languages: String
        let available: Bool
        let lagMs: Int
        let lagText: String
        let responsive: Bool
        /// False for models the app must never choose on someone's behalf. Currently Kroko,
        /// whose publisher declares no licence. See THIRD-PARTY-NOTICES.md; the flag rides
        /// on the wire so the screen that preselects can honour it.
        let autoSelect: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, detail, languages, available, responsive
            case approxMb = "approx_mb"
            case lagMs = "lag_ms"
            case lagText = "lag_text"
            case autoSelect = "auto_select"
        }
    }
}

/// Commands a client may send. Pinned by the same contract test.
enum BackendCommand {
    case start
    case stop
    case toggle
    case listModels
    case downloadModel(String)
    case renameSpeaker(id: Int, name: String)
    case setSelf(id: Int, value: Bool)
    case mergeSpeakers(source: Int, target: Int)
    case deleteSpeaker(id: Int)
    case resetSpeakers
    case startRecording(path: String?)
    case stopRecording

    var payload: [String: Any] {
        switch self {
        case .start:
            return ["cmd": "start"]
        case .stop:
            return ["cmd": "stop"]
        case .toggle:
            return ["cmd": "toggle"]
        case .listModels:
            return ["cmd": "list_models"]
        case .downloadModel(let model):
            return ["cmd": "download_model", "model": model]
        case .renameSpeaker(let id, let name):
            return ["cmd": "rename_speaker", "id": id, "name": name]
        case .setSelf(let id, let value):
            return ["cmd": "set_self", "id": id, "value": value]
        case .mergeSpeakers(let source, let target):
            return ["cmd": "merge_speakers", "source": source, "target": target]
        case .deleteSpeaker(let id):
            return ["cmd": "delete_speaker", "id": id]
        case .resetSpeakers:
            return ["cmd": "reset_speakers"]
        case .startRecording(let path):
            // The destination rides on the command that starts the recording rather than
            // being configured once, so changing the folder mid-recording takes effect on
            // the next one instead of moving an open file.
            var out: [String: Any] = ["cmd": "start_recording"]
            if let path, !path.isEmpty { out["path"] = path }
            return out
        case .stopRecording:
            return ["cmd": "stop_recording"]
        }
    }

    func encoded() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}
