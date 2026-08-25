import Foundation
import AppKit

/// Owns the Python speech engine as a child process.
///
/// This is the bridge, and it is deliberately temporary. Running the existing backend means
/// the macOS app can put real captions on screen against the protocol that already exists,
/// before anyone has decided which native engine wins. `docs/MACOS-PORT.md` gates that
/// decision on a measurement rather than on a preference, and this is what lets the UI be
/// built and judged while that measurement is still outstanding.
///
/// What it must not become is the shipping architecture. An embedded CPython inside a signed
/// .app needs `com.apple.security.cs.disable-library-validation` to load its C extensions,
/// which notarisation permits and App Review is reported to refuse. Every week this class
/// survives is a week the App Store stays closed.
///
/// A separate process rather than an in-process library, while it lasts, for the same reason
/// the Windows build gives: a crash in inference leaves the window alive and reconnecting
/// instead of taking the app down mid-conversation.
@MainActor
final class BackendHost: ObservableObject {

    enum Status: Equatable {
        case notStarted
        case running
        /// Exited without being asked to. The message is for a human; the detail is for a
        /// bug report.
        case failed(String)
    }

    @Published private(set) var status: Status = .notStarted

    /// Whether an engine has ever been asked for in this launch. `SunnoApp.startUp` is driven by
    /// `onAppear`, which fires again whenever SwiftUI rebuilds the hierarchy, and startup is not
    /// something to do twice.
    private var hasStarted = false

    /// True exactly once per launch. Claimed before any awaiting, so a second `onAppear` cannot
    /// slip through while the first is still bringing capture up.
    func claimStartUp() -> Bool {
        guard !hasStarted else { return false }
        hasStarted = true
        return true
    }

    private var process: Process?
    private var signalSources: [DispatchSourceSignal] = []

    /// The child's pid, kept where a termination handler can read it without hopping to the
    /// main actor. An awaited hop would not run: by the time it was scheduled the process
    /// would already be gone and the engine orphaned, which is the whole bug being fixed.
    ///
    /// `nonisolated(unsafe)` because a quit handler and the process's own termination handler
    /// reach it from different queues. It is a single word written at launch and cleared at
    /// exit, and the worst a torn read could do is send SIGTERM to a pid that has already gone.
    private nonisolated(unsafe) static var liveChildPID: pid_t = 0

    let httpPort: Int
    let wsPort: Int

    init(httpPort: Int = 8765, wsPort: Int = 8766) {
        self.httpPort = httpPort
        self.wsPort = wsPort
        installTerminationGuards()
    }

    /// Where the engine lives.
    ///
    /// Two layouts, and the shipped one is checked first.
    ///
    /// **Inside the bundle**, at `Contents/Resources/engine`, which is what a downloaded copy
    /// has: its own Python, `server/`, `ui/` and the WhisperKit service. Nothing outside the
    /// app is required, which is the whole point — a copy handed to somebody else has never
    /// seen this repository and never will.
    ///
    /// **Beside the checkout**, found by walking up from the bundle, which is what a
    /// development build has. Walking rather than hardcoding a depth, because the depth changes
    /// with the build configuration and the failure is a silent "engine never starts".
    ///
    /// The bundled copy wins deliberately. A developer running a shipped build should get the
    /// engine that was shipped with it, not whatever happens to be in a checkout above it.
    private func engineRoot() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/engine")
            .standardizedFileURL
        if FileManager.default.fileExists(atPath:
            bundled.appendingPathComponent("server/app.py").path) {
            return bundled
        }

        var directory = Bundle.main.bundleURL
        for _ in 0..<8 {
            directory = directory.deletingLastPathComponent()
            let marker = directory.appendingPathComponent("server/app.py").standardizedFileURL
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory.standardizedFileURL
            }
        }
        return nil
    }

    private func interpreter(in root: URL) -> URL? {
        // The interpreter that shipped with the engine, then a development venv, then whatever
        // is on the machine. The first is the only one a downloaded copy can count on: a Mac
        // that has never had Xcode's Command Line Tools installed has no usable python3 at all,
        // and /usr/bin/python3 there is a stub that offers to install them.
        for candidate in ["python/bin/python3", ".venv/bin/python"] {
            let path = root.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }

        for candidate in ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    func start(model: String?, device: Int?, loopbackDevice: Int?, pcmPort: UInt16? = nil,
               forceCPU: Bool) {
        guard process == nil else { return }

        // Before anything binds a port, clear away an engine a previous run left behind.
        // Without this the new child dies on the port conflict and the app quietly attaches
        // to the stale one, which presents as a working app showing state that stopped
        // updating: a model downloaded a minute ago still listed as missing, for instance.
        Self.reapOrphanedChild()

        guard let root = engineRoot() else {
            status = .failed("Could not find the speech engine. It should be at server/ "
                             + "beside the app.")
            return
        }
        guard let python = interpreter(in: root) else {
            status = .failed("No Python found. Run scripts/setup-engine.sh to create .venv.")
            return
        }

        var arguments = ["-m", "server.app",
                         "--http-port", String(httpPort),
                         "--ws-port", String(wsPort)]
        if let model { arguments.append(contentsOf: ["--model", model]) }
        if let device { arguments.append(contentsOf: ["--device", String(device)]) }
        if let loopbackDevice {
            arguments.append(contentsOf: ["--loopback-device", String(loopbackDevice)])
        }
        // System audio does not arrive as a device on macOS. The client captures it with
        // ScreenCaptureKit and serves it here as mono float32 at 16 kHz.
        if let pcmPort {
            arguments.append(contentsOf: ["--pcm-port", String(pcmPort)])
        }
        if forceCPU { arguments.append(contentsOf: ["--compute-device", "cpu"]) }

        let task = Process()
        task.executableURL = python
        task.arguments = arguments
        task.currentDirectoryURL = root

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        // Keep the writable profile where macOS expects it rather than in the Linux-style
        // ~/.sunno that server/paths.py falls back to on any non-Windows platform.
        environment["Sunno_DATA_DIR"] = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sunno").path
        task.environment = environment

        // stdout is read and discarded rather than inherited. The backend prints latency and
        // speaker ids but never transcript text, and inheriting would put it in the system
        // log where nobody chose to keep it.
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        task.terminationHandler = { [weak self] finished in
            // The pid on disk goes with the child that owned it, and only that one. A handler
            // for a process we already replaced must not erase the record of its successor.
            BackendHost.forgetChild(pid: finished.processIdentifier)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only the process that is still the current one may report a failure.
                //
                // `stop()` followed by `start()` is an ordinary event here: changing the
                // device or switching to system audio replaces the engine deliberately. The
                // outgoing child's handler runs on a background queue and therefore arrives
                // *after* the replacement is already running, so a flag saying "we are
                // stopping" is read too late and the dead engine's exit is reported over a
                // healthy one. It said "stopped unexpectedly (exit 15)" — SIGTERM, the signal
                // this class sends itself — and the message never cleared, because nothing
                // starts an engine again once one is running.
                guard self.process === finished else { return }
                self.process = nil
                self.status = .failed(
                    "The speech engine stopped unexpectedly (exit \(finished.terminationStatus)).")
            }
        }

        do {
            try task.run()
            process = task
            Self.rememberChild(pid: task.processIdentifier)
            status = .running
        } catch {
            // The reason, not just the fact. "could not be started" on its own sends someone
            // looking at the backend when the answer is usually about this side: a venv that
            // names an interpreter which has since been removed, most often.
            status = .failed("The speech engine could not be started. \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let task = process else {
            Self.forgetChild()
            status = .notStarted
            return
        }
        process = nil
        task.terminate()

        // Bounded, and short. The replacement engine binds the same two ports, and SIGTERM is
        // not instant: starting the new one while the old still holds 8765 kills it on a bind
        // error, which presents as an engine that will not start for no visible reason. Python
        // exits on SIGTERM in a few milliseconds, so this almost never spins more than once.
        let deadline = Date().addingTimeInterval(2)
        while task.isRunning, Date() < deadline {
            usleep(10_000)
        }

        Self.forgetChild()
        status = .notStarted
    }

    // MARK: - Not leaving the engine behind
    //
    // A child process outlives its parent on Unix unless something intervenes, and an
    // orphaned engine keeps the microphone open and both ports bound. That is worse than it
    // sounds, because the next launch does not fail loudly: the new child dies on the port
    // conflict and the app connects to the stale engine instead, so it looks like a working
    // app that has quietly stopped keeping up with reality.
    //
    // Three exits have to be covered, and no single mechanism covers them all:
    //
    //   Quit, Cmd-Q, the app closing   `NSApplication.willTerminateNotification`
    //   SIGTERM and SIGINT, ie `kill`  a dispatch signal source, because the default action
    //                                  for both is to die at once, running no notification
    //   SIGKILL and a crash            nothing in the process can run, so the pid is written
    //                                  to disk and the next launch reaps it
    //
    // The third is the only one that survives a crash, and it is the reason a pid file exists
    // rather than just a quit handler.

    private func installTerminationGuards() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // Synchronous on purpose. An async hop here does not get to run.
            BackendHost.terminateLiveChild()
        }

        for signalNumber in [SIGTERM, SIGINT] {
            // The default action has to be suppressed first, or the process dies before the
            // source is ever given the signal.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                BackendHost.terminateLiveChild()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - The pid on disk

    /// Identity, not just a number. A pid alone is not enough to kill by: the system reuses
    /// them, and a stale file naming a pid that now belongs to something else is a loaded gun.
    /// The start time is what makes it safe, and `exec` preserves both halves, which matters
    /// more than it sounds: a framework CPython re-execs itself into
    /// `Python.app/Contents/MacOS/Python` moments after launch, so the executable path of this
    /// child is not even stable for the length of its own life. It was tried as a third check
    /// and had to be removed, because it made the reap silently never fire.
    private struct ChildRecord: Codable {
        let pid: pid_t
        let startSeconds: Int64
        let startMicroseconds: Int32
    }

    /// Alongside the profile the backend already writes, which is the directory `start()`
    /// hands the child as `Sunno_DATA_DIR`.
    private nonisolated static func recordURL() -> URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sunno", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.appendingPathComponent("engine.pid")
    }

    private nonisolated static func rememberChild(pid: pid_t) {
        liveChildPID = pid
        guard let started = startTime(of: pid), let url = recordURL() else { return }
        let record = ChildRecord(pid: pid,
                                 startSeconds: Int64(started.tv_sec),
                                 startMicroseconds: Int32(started.tv_usec))
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Forget a specific child, and only if it is still the one on record. The outgoing engine's
    /// termination handler can arrive after its replacement has been remembered, and clearing
    /// unconditionally there would leave the new child with no pid file and nothing to reap it.
    private nonisolated static func forgetChild(pid: pid_t) {
        guard liveChildPID == 0 || liveChildPID == pid else { return }
        forgetChild()
    }

    private nonisolated static func forgetChild() {
        liveChildPID = 0
        guard let url = recordURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func terminateLiveChild() {
        let pid = liveChildPID
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        forgetChild()
    }

    /// Kills an engine a previous run left behind, and only that. Every check here exists to
    /// make sure the thing being killed is the process that was recorded rather than whatever
    /// inherited its pid afterwards.
    private nonisolated static func reapOrphanedChild() {
        guard let url = recordURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        // Removed whatever happens next, including when it cannot be read. A file that failed
        // to decode would otherwise sit there being re-examined on every launch forever.
        defer { try? FileManager.default.removeItem(at: url) }

        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(ChildRecord.self, from: data)
        else { return }

        // Gone already, which is the normal case after a clean quit.
        guard let started = startTime(of: record.pid) else { return }
        // Same pid, different process. Leave it entirely alone. A pid handed out again would
        // have to have been forked in the same microsecond to get past this.
        guard Int64(started.tv_sec) == record.startSeconds,
              Int32(started.tv_usec) == record.startMicroseconds
        else { return }

        kill(record.pid, SIGTERM)
        // Briefly, and only when an orphan was actually found. The engine closes its ports on
        // SIGTERM well inside this; the deadline is here so a wedged one cannot hold up launch.
        for _ in 0..<30 {
            if startTime(of: record.pid) == nil { return }
            usleep(50_000)
        }
        kill(record.pid, SIGKILL)
    }

    private nonisolated static func startTime(of pid: pid_t) -> timeval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let ok = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0) == 0
        }
        // sysctl reports success with a zero-length answer for a pid that no longer exists.
        guard ok, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }
}
