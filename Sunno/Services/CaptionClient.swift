import Foundation
import Combine

/// Generation-safe reconnects and serialized, bounded control sends.
@MainActor
final class CaptionClient: ObservableObject {
    enum Connection: Equatable {
        case idle
        case connecting
        case connected
        case waiting(attempt: Int)
    }
    @Published private(set) var connection: Connection = .idle
    @Published private(set) var undecodableEvents = 0
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private var port = 8766
    private var host = "127.0.0.1"
    private var shouldRun = false
    private var attempt = 0
    private var generation = 0
    private var retry: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?
    private let decoder = JSONDecoder()
    var onEvent: ((BackendEvent) -> Void)?
    var onConnected: (() -> Void)?

    func connect(host: String = "127.0.0.1", port: Int = 8766) {
        disconnect()
        self.host = host
        self.port = port
        shouldRun = true
        attempt = 0
        openSocket()
    }

    func disconnect() {
        generation += 1
        shouldRun = false
        retry?.cancel()
        retry = nil
        sendTail?.cancel()
        sendTail = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connection = .idle
    }

    @discardableResult
    func send(_ command: BackendCommand) -> Bool {
        guard connection == .connected, let socket = task,
              let text = try? command.encoded() else { return false }
        let previous = sendTail
        let epoch = generation
        sendTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.generation == epoch, self.task === socket else { return }
            // Cancel the actual socket on timeout, so a framework send cannot pin the queue.
            let timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, self.generation == epoch, self.task === socket else { return }
                self.scheduleReconnect(epoch: epoch)
            }
            defer { timeout.cancel() }
            do { try await socket.send(.string(text)) }
            catch {
                if self.generation == epoch, self.task === socket { self.scheduleReconnect(epoch: epoch) }
            }
        }
        return true
    }

    private func openSocket() {
        guard shouldRun, let url = URL(string: "ws://\(host):\(port)") else { return }
        generation += 1
        connection = .connecting
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
        receiveLoop(on: socket, epoch: generation)
    }

    private func receiveLoop(on socket: URLSessionWebSocketTask, epoch: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.shouldRun, self.generation == epoch, self.task === socket else { return }
                switch result {
                case .success(let message):
                    if self.connection != .connected {
                        self.connection = .connected
                        self.attempt = 0
                        self.onConnected?()
                    }
                    self.handle(message)
                    self.receiveLoop(on: socket, epoch: epoch)
                case .failure:
                    self.scheduleReconnect(epoch: epoch)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        guard let data else { return }
        do {
            let event = try decoder.decode(BackendEvent.self, from: data)
            if event.kind == .unknown { undecodableEvents += 1 }
            onEvent?(event)
        } catch { undecodableEvents += 1 }
    }

    private func scheduleReconnect(epoch: Int) {
        guard shouldRun, generation == epoch else { return }
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sendTail?.cancel()
        sendTail = nil
        retry?.cancel()
        attempt += 1
        connection = .waiting(attempt: attempt)
        let token = generation
        let delay = min(2.0, 0.15 * Double(attempt))
        retry = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.shouldRun, self.generation == token else { return }
            self.openSocket()
        }
    }
}
