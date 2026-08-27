import Foundation
import SwiftUI

/// What the app believes is happening with a recording.
///
/// idle → recording → saving → saved → idle. Nothing here writes files. The engine owns the
/// recording and this only reflects what it reports, so a state showing on screen is one the
/// engine has actually reached rather than one the button hoped for.
///
/// The elapsed count comes from the engine, not from a local stopwatch. They disagree the
/// moment capture stops and starts inside one recording — a pause, a swapped microphone —
/// and the engine's figure is the length of the audio, which is what the finished file
/// actually contains. A local timer would drift away from the file and be wrong in the one
/// place a user might check it against.
@MainActor
final class RecordingController: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case saving
        case saved(name: String, duration: Double)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0

    /// The folder being written to, handed back to the engine as `resume` when it restarts
    /// for a new microphone or model. Without it a restart mid-recording would leave the
    /// audio behind and begin a second file.
    private(set) var activeFolder: String?

    /// The last recording saved this session, so "reveal in Finder" can open the recording
    /// itself rather than the folder above it.
    private(set) var lastSavedFolder: String?

    var isRecording: Bool { state == .recording }

    private var ticker: Timer?
    private var savedHold: Timer?

    /// Raised when a recording could not be started or saved, for the banner to show.
    var onFailure: ((String) -> Void)?

    func apply(_ event: BackendEvent) {
        guard event.kind == .recording else { return }

        switch event.state {
        case "recording":
            elapsed = event.elapsedS ?? elapsed
            activeFolder = event.folder ?? activeFolder
            enterRecording()

        case "saving":
            stopTicking()
            state = .saving

        case "saved":
            stopTicking()
            activeFolder = nil
            lastSavedFolder = event.folder
            state = .saved(name: event.name ?? "Recording",
                           duration: event.durationS ?? elapsed)
            // Held long enough to be seen and short enough not to become the resting state.
            // The tick is the only confirmation that a meeting is now a file, so it must not
            // be missable, and it must not linger as though something still needs doing.
            savedHold?.invalidate()
            savedHold = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.enterIdle() }
            }

        case "failed":
            activeFolder = nil
            enterIdle()
            let detail = event.message.map { " \($0)" } ?? ""
            onFailure?("Could not save the recording.\(detail)")

        default:
            activeFolder = nil
            enterIdle()
        }
    }

    /// Forget everything about a recording. Used when the engine dies outright, where the
    /// pill would otherwise sit there claiming to be recording into a process that is gone.
    func reset() {
        stopTicking()
        savedHold?.invalidate()
        savedHold = nil
        activeFolder = nil
        elapsed = 0
        state = .idle
    }

    private func enterRecording() {
        savedHold?.invalidate()
        savedHold = nil
        state = .recording
        guard ticker == nil else { return }
        // Counts locally between frames purely so the display moves once a second; every
        // engine frame reasserts the real figure, so this can drift for at most one tick.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
    }

    private func enterIdle() {
        stopTicking()
        savedHold?.invalidate()
        savedHold = nil
        elapsed = 0
        state = .idle
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    /// `3:20`, not `03:20` — a leading zero on the minutes carries no information.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
