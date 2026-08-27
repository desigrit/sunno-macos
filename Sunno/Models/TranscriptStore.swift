import Foundation
import SwiftUI

/// One line in the transcript.
///
/// Speaker identity is held as an id rather than a resolved name, and the name is looked up
/// through the roster at render time. That is not a style preference: renaming, merging and
/// deleting a speaker all rewrite history, and a line that had baked in a copy of the name
/// would keep showing the old one. The Windows build learned this the hard way, and its
/// comment is worth repeating: in a transcript, for a deaf user, this is the only record of
/// who said what.
struct CaptionLine: Identifiable, Equatable {
    let id: Int
    var text: String
    var speakerId: Int?
    var isFinal: Bool
    var clarity: Int?
    var words: [WordScore]
    var startedAt: Date?

    struct WordScore: Equatable {
        let text: String
        let probability: Double
        var isUncertain: Bool { probability < Theme.lowConfidenceBelow }
    }

    var timeLabel: String {
        guard let startedAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: startedAt)
    }
}

/// A person the engine has heard.
struct SpeakerRow: Identifiable, Equatable {
    let id: Int
    var label: String
    var named: Bool
    var isSelf: Bool

    /// "You" wins over the given name on the line itself, matching the Windows build. The
    /// sidebar shows both, because there it is a roster rather than an attribution.
    var displayLabel: String { isSelf ? "You" : label }
    var sidebarLabel: String { isSelf ? "\(label) (You)" : label }
}

/// Everything on screen, assembled from the event stream.
///
/// The ordering rules here are the ones the backend guarantees and the ones a client is
/// obliged to honour. `speaker_merged` and `speaker_deleted` always arrive BEFORE the roster
/// that reflects them, precisely so this type can move already-displayed lines onto the
/// surviving id first. Handle them in the other order and those captions keep the name of
/// someone the user just asked the app to forget.
@MainActor
final class TranscriptStore: ObservableObject {

    @Published private(set) var lines: [CaptionLine] = []
    @Published private(set) var speakers: [SpeakerRow] = []
    @Published private(set) var catalog: [BackendEvent.CatalogEntry] = []

    @Published private(set) var state: String = "starting"
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var activeModel: String?
    /// The audio device name, held for display only. Deliberately never written to a log or
    /// into the diagnostics export: "Headset (R-Phonak hearing aid)" is health information
    /// arriving through a field nobody thinks of as sensitive.
    @Published private(set) var deviceName: String?

    /// The two values that move at audio rate, in objects of their own so a level event ten
    /// times a second does not invalidate every view watching this store. See `AudioMeter`.
    let meter = AudioMeter()
    let clock = SessionClock()

    @Published private(set) var problem: Problem?
    @Published private(set) var download: Download?
    @Published private(set) var needsModelChoice: Bool = false

    struct Problem: Equatable {
        let message: String
        /// `mic_denied`, `mic_unavailable`, `capture_failed`, or nil when the engine could
        /// not say. The UI offers a specific remedy only for the ones it recognises.
        let code: String?
        var severity: Severity = .warning

        /// How alarming this is, which the banner renders differently.
        ///
        /// Three levels rather than one, because once the app started reporting that a
        /// microphone had been swapped, every one of those arrived wearing the same orange
        /// triangle as a dead engine. "Your headset went away and I picked another one" is
        /// news, not a fault, and dressing it as a fault teaches people to ignore the banner
        /// that will one day be telling them nothing is being transcribed.
        enum Severity: Equatable {
            case info
            case warning
            case error
        }
    }

    struct Download: Equatable {
        let model: String
        var percent: Double
        var failed: String?
    }

    /// Surfaced by the app rather than the engine, for failures the engine never sees: it
    /// cannot report that system audio was refused, because on macOS it never touches it.
    func reportProblem(_ message: String, code: String?,
                       severity: Problem.Severity = .warning) {
        problem = Problem(message: message, code: code, severity: severity)
    }

    /// Something worth saying that is not a fault: a microphone that changed, a folder that
    /// will be used next time.
    ///
    /// Sticky in the same way a problem is, and deliberately: a notice cleared by the next
    /// `listening` frame would vanish within a second of appearing, which is how the Windows
    /// build learned to make these survive status updates.
    func note(_ message: String) {
        problem = Problem(message: message, code: nil, severity: .info)
    }

    /// Clear whatever the banner is showing. The user has dealt with it, or it stopped being
    /// true.
    func dismissProblem() {
        problem = nil
    }

    func speaker(_ id: Int?) -> SpeakerRow? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }
    }

    func clear() {
        lines.removeAll()
        // A new conversation, so the count starts over. The only thing that resets it.
        clock.reset()
    }

    // MARK: - Event intake

    func apply(_ event: BackendEvent) {
        switch event.kind {

        case .status:
            state = event.state ?? state
            if let running = event.running { isRunning = running }
            if let model = event.model { activeModel = model }
            if let device = event.device { deviceName = device }
            // Captions starting clears a fault, because the fault is evidently over. A notice
            // is not a fault and must survive: "your microphone changed" arrives moments
            // before the engine reports listening on the replacement, so clearing on that
            // frame would delete the explanation a fraction of a second after showing it.
            if event.state == "listening", problem?.severity != .info { problem = nil }

            // The clock follows capture, not the socket. Losing the connection does not stop
            // the microphone, and the count measures the conversation rather than any one
            // capture run.
            if event.state == "listening", isRunning {
                clock.start()
            } else if isRunning == false || event.state == "stopped" {
                clock.pause()
                meter.silence()
            }

        case .partial, .final:
            upsert(event)

        case .discard:
            if let id = event.id { lines.removeAll { $0.id == id && !$0.isFinal } }

        case .speechStart:
            break   // No visual today. Kept for latency work; see the contract test.

        case .level:
            meter.update(db: event.db, speaking: event.speaking ?? false)
            // Proof that capture is alive, which is the whole basis of the stall warning.
            clock.sawAudio()

        case .roster:
            speakers = (event.speakers ?? []).map {
                SpeakerRow(id: $0.id, label: $0.label, named: $0.named, isSelf: $0.isSelf)
            }

        case .speakerMerged:
            // Before the roster, on purpose. See the type comment.
            if let from = event.mergedFrom, let into = event.mergedInto {
                for index in lines.indices where lines[index].speakerId == from {
                    lines[index].speakerId = into
                }
            }

        case .speakerDeleted:
            if let id = event.id {
                for index in lines.indices where lines[index].speakerId == id {
                    lines[index].speakerId = nil
                }
            }

        case .modelRequired:
            catalog = event.catalog ?? []
            needsModelChoice = true

        case .modelCatalog:
            catalog = event.catalog ?? []
            activeModel = event.current ?? activeModel

        case .downloadStarted:
            download = Download(model: event.model ?? "", percent: 0, failed: nil)

        case .downloadProgress:
            if var current = download {
                current.percent = event.percent ?? current.percent
                download = current
            }

        case .downloadComplete:
            download = nil
            needsModelChoice = false

        case .downloadFailed:
            download = Download(model: event.model ?? "", percent: 0,
                                failed: event.message ?? "The download did not finish.")

        case .error:
            if let running = event.running { isRunning = running }
            // A capture problem is a warning: captions have stopped but the app has not.
            // Anything the engine could not name is an error, because an unrecognised
            // failure is the one most likely to mean nothing is working.
            let known = ["mic_denied", "mic_unavailable", "capture_failed", "screen_denied"]
            problem = Problem(message: event.message ?? "Something went wrong.",
                              code: event.code,
                              severity: known.contains(event.code ?? "") ? .warning : .error)

        case .recording:
            // Owned by RecordingController, which the app hands every event to. Named here
            // rather than swept into `unknown` so the compiler keeps making this decision
            // explicit if the protocol grows.
            break

        case .unknown:
            break
        }
    }

    /// Provisional text is replaced in place by the final for the same utterance, exactly
    /// once, which is the BBC and DCMP live-subtitle convention the Windows build follows:
    /// corrections land at the sentence boundary rather than churning word by word.
    private func upsert(_ event: BackendEvent) {
        guard let id = event.id else { return }

        let words = (event.words ?? []).map {
            CaptionLine.WordScore(text: $0.t, probability: $0.p)
        }
        let startedAt = event.startedAt.map { Date(timeIntervalSince1970: $0) }

        if let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].text = event.text ?? lines[index].text
            lines[index].isFinal = (event.kind == .final)
            lines[index].clarity = event.clarity
            lines[index].words = words
            if let speakerId = event.speakerId { lines[index].speakerId = speakerId }
        } else {
            lines.append(CaptionLine(
                id: id,
                text: event.text ?? "",
                speakerId: event.speakerId,
                isFinal: event.kind == .final,
                clarity: event.clarity,
                words: words,
                startedAt: startedAt
            ))
        }
    }
}
