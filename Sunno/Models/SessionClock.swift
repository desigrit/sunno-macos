import Foundation

/// How long this conversation has been recording, and whether audio is still arriving.
///
/// Ported from `MainWindow.xaml.cs:704-830`, including the reasoning, because both halves are
/// less obvious than they look.
///
/// **The count accumulates across pauses and only a new conversation resets it.** Ducking out
/// for a private aside is what the pause button is for, and zeroing a forty minute reading
/// because somebody stepped away for thirty seconds would punish exactly the behaviour the
/// control exists to encourage.
///
/// **A counter that keeps climbing is read as "everything is fine", so it must not keep
/// climbing once audio has stopped arriving.** The capture thread can die while the process
/// lives. `CONTEXT.md` records this being got wrong in both directions: the stall check was
/// first exempted for loopback to silence a false alarm, which removed the true alarm with it,
/// and a Phonak headset dropping off Bluetooth mid-session left the app showing a running
/// clock above a transcript that could never gain another line.
@MainActor
final class SessionClock: ObservableObject {

    /// Four seconds, as on Windows. Long enough that an ordinary gap in speech never trips it,
    /// short enough that somebody is not reading a dead transcript for a minute first.
    static let stallAfter: TimeInterval = 4

    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isStalled = false

    private var accumulated: TimeInterval = 0
    private var startedAt: Date?
    /// Nil while paused, which is also what makes the stall check dormant then: a released
    /// microphone is not a stalled one.
    private var lastAudioAt: Date?
    private var ticker: Timer?

    var hasRun: Bool { elapsed > 0 }

    /// Starting, not restarting. Repeated "listening" reports during one run are harmless
    /// because a clock that is already running is left alone.
    func start() {
        // The audio deadline is refreshed unconditionally even so. A "listening" report is
        // itself proof of life, and after a reconnect the deadline would otherwise still be
        // carrying the whole outage and cry "No audio" a second later. The one indicator that
        // must never raise a false alarm is the one claiming captions have stopped.
        lastAudioAt = Date()
        isStalled = false

        guard startedAt == nil else { return }
        startedAt = Date()
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes, so the count keeps running while a menu is open or the window is
        // being dragged. A clock that freezes whenever the device picker is open would look
        // like the stall it exists to report.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        tick()
    }

    /// Freeze where it is. Deliberately not a reset: see the type comment.
    func pause() {
        if let startedAt {
            accumulated += Date().timeIntervalSince(startedAt)
        }
        startedAt = nil
        lastAudioAt = nil
        isStalled = false
        ticker?.invalidate()
        ticker = nil
        elapsed = accumulated
    }

    /// A new conversation: the transcript was cleared, so the count starts over.
    func reset() {
        pause()
        accumulated = 0
        elapsed = 0
    }

    func sawAudio() {
        lastAudioAt = Date()
        if isStalled { isStalled = false }
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = accumulated + Date().timeIntervalSince(startedAt)

        guard let lastAudioAt else { return }
        let stalled = Date().timeIntervalSince(lastAudioAt) > Self.stallAfter
        if stalled != isStalled { isStalled = stalled }
    }

    /// `m:ss` under an hour, `h:mm:ss` past it, matching the Windows format exactly.
    var display: String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours >= 1
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
