import Foundation

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

    private var process: Process?
    private var stopping = false

    let httpPort: Int
    let wsPort: Int

    init(httpPort: Int = 8765, wsPort: Int = 8766) {
        self.httpPort = httpPort
        self.wsPort = wsPort
    }

    /// Where the backend lives during development.
    ///
    /// Two layouts are tried, in order, because both are legitimate. The backend is a
    /// submodule of this repository at `external/sunno`, which is the normal case. It may also
    /// sit beside this checkout as a sibling clone, which is what you get if somebody clones
    /// the two repositories separately rather than recursively, and that is common enough to
    /// be worth handling rather than failing on.
    ///
    /// Walks up from the app bundle rather than hardcoding a relative depth, because the depth
    /// changes with the build configuration and the failure is a silent "engine never starts".
    private func developmentRoot() -> URL? {
        let candidates = ["external/sunno", "../sunno"]

        var directory = Bundle.main.bundleURL
        for _ in 0..<8 {
            directory = directory.deletingLastPathComponent()
            for candidate in candidates {
                let root = directory.appendingPathComponent(candidate).standardizedFileURL
                let marker = root.appendingPathComponent("server/app.py")
                if FileManager.default.fileExists(atPath: marker.path) {
                    return root
                }
            }
        }
        return nil
    }

    private func interpreter(in root: URL) -> URL? {
        // A venv inside the backend checkout, then a bare python3 on PATH. No bundled runtime:
        // this class exists only for development, and bundling an interpreter is the thing it
        // is meant to avoid.
        let venv = root.appendingPathComponent(".venv/bin/python")
        if FileManager.default.fileExists(atPath: venv.path) { return venv }

        for candidate in ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    func start(model: String?, device: Int?, loopbackDevice: Int?, forceCPU: Bool) {
        guard process == nil else { return }
        stopping = false

        guard let root = developmentRoot() else {
            status = .failed("Could not find the Sunno backend. Run "
                             + "'git submodule update --init --recursive'.")
            return
        }
        guard let python = interpreter(in: root) else {
            status = .failed("No Python interpreter found. Create a .venv in external/sunno.")
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
            Task { @MainActor [weak self] in
                guard let self, !self.stopping else { return }
                self.process = nil
                self.status = .failed(
                    "The speech engine stopped unexpectedly (exit \(finished.terminationStatus)).")
            }
        }

        do {
            try task.run()
            process = task
            status = .running
        } catch {
            status = .failed("The speech engine could not be started.")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        status = .notStarted
    }
}
