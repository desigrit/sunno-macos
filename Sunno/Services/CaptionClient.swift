import Foundation

/// The socket to the speech engine.
///
/// Reconnects on its own, deliberately and indefinitely. The engine is a child process that
/// can be restarted underneath this connection: changing the input device or the model tears
/// it down and brings it back, and that is a normal Tuesday rather than an error. A client
/// that gave up after a few attempts would leave someone looking at a frozen transcript with
/// no way back except quitting the app.
///
/// Decoding never throws upward. An event this build does not understand is counted and
/// dropped, because the alternative is that a newer backend silently stops the captions of
/// someone who is mid-conversation. `BackendEvent.Kind.unknown` is the mechanism; the counter
/// exists so the diagnostics export can say it happened.
@MainActor
final class CaptionClient: ObservableObject {

    enum Connection: Equatable {
        case idle
        case connecting
        case connected
        /// Waiting to retry. The engine restarting looks exactly like this.
        case waiting(attempt: Int)
    }

    @Published private(set) var connection: Connection = .idle

    /// Events that decoded but named a type this build has never heard of. Surfaced in
    /// diagnostics rather than logged and forgotten: a non-zero count here means the app and
    /// the engine are from different versions, which explains a whole class of "it just does
    /// not do that any more" reports.
    @Published private(set) var undecodableEvents: Int = 0

    private var task: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    private var port: Int = 8766
    private var host: String = "127.0.0.1"
    private var shouldRun = false
    private var attempt = 0
    private let decoder = JSONDecoder()

    /// Called on the main actor for every decoded event.
    var onEvent: ((BackendEvent) -> Void)?

    // MARK: - Lifecycle

    func connect(host: String = "127.0.0.1", port: Int = 8766) {
        self.host = host
        self.port = port
        shouldRun = true
        attempt = 0
        openSocket()
    }

    func disconnect() {
        shouldRun = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connection = .idle
    }

    func send(_ command: BackendCommand) {
        guard let task else { return }
        do {
            let text = try command.encoded()
            task.send(.string(text)) { error in
                if error != nil {
                    // The read loop will notice the same failure and drive the reconnect.
                    // Handling it here as well would produce two overlapping retry ladders.
                }
            }
        } catch {
            // Encoding a fixed dictionary of scalars cannot realistically fail. Swallowed
            // rather than crashed on: losing one command is recoverable, and this app should
            // not take itself down in front of a room.
        }
    }

    // MARK: - Socket

    private func openSocket() {
        guard shouldRun else { return }
        guard let url = URL(string: "ws://\(host):\(port)") else { return }

        connection = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(on: task)
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.shouldRun, self.task === task else { return }

                switch result {
                case .success(let message):
                    if self.connection != .connected {
                        self.connection = .connected
                        self.attempt = 0
                    }
                    self.handle(message)
                    self.receiveLoop(on: task)

                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw):    data = raw
        @unknown default:       data = nil
        }
        guard let data else { return }

        do {
            let event = try decoder.decode(BackendEvent.self, from: data)
            if event.kind == .unknown { undecodableEvents += 1 }
            onEvent?(event)
        } catch {
            undecodableEvents += 1
        }
    }

    /// Backs off to a ceiling and then keeps trying at that interval.
    ///
    /// The ceiling matters more than the curve. A model switch takes about half a minute, so
    /// a ladder that gave up, or that backed off to minutes, would leave the window dark long
    /// after the engine was ready. Two seconds is short enough that a returning engine is
    /// picked up almost immediately and long enough not to spin.
    private func scheduleReconnect() {
        guard shouldRun else { return }
        // Cancel before dropping the reference. Releasing a task that is still open leaves
        // the socket to be torn down whenever it happens to be collected, and a stale one can
        // still deliver into a closure that then races the replacement.
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        attempt += 1
        connection = .waiting(attempt: attempt)

        let delay = min(2.0, 0.15 * Double(attempt))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.openSocket()
        }
    }
}
