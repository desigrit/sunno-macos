import Foundation
import Combine

/// Latest-request-wins input selection. Only a capture acknowledgement commits preferences.
@MainActor
final class InputSwitch: ObservableObject {
    @Published private(set) var pending: AudioInputTarget?
    private(set) var requestID: String?
    private(set) var wanted = true
    private var unacknowledgedTransport = false
    private var suspended = false
    private var intent = 0
    var send: ((BackendCommand) -> Bool)?
    var commit: ((AudioInputTarget) -> Void)?

    func nextIntent() -> Int { intent += 1; return intent }
    func isCurrent(_ value: Int) -> Bool { value == intent }

    func request(_ target: AudioInputTarget) {
        pending = target
        requestID = UUID().uuidString
        replayInput()
    }

    func setRunning(_ running: Bool) {
        wanted = running
        unacknowledgedTransport = true
        _ = send?(running && !suspended ? .start : .stop)
    }

    func suspend() {
        suspended = true
        _ = send?(.stop)
    }

    func resume() {
        suspended = false
        reconnected()
    }

    func reconnected() {
        // Preserve a pause across backend replacement and control reconnection.
        unacknowledgedTransport = true
        _ = send?(wanted && !suspended ? .start : .stop)
        if !suspended { replayInput() }
    }

    private func replayInput() {
        if let pending, let requestID { _ = send?(.setInput(pending, requestID: requestID)) }
    }

    /// False means this acknowledgement belongs to a superseded selection.
    func apply(_ event: BackendEvent) -> Bool {
        guard event.kind == .input else { return true }
        if let requestID, event.requestID != requestID { return false }
        if !suspended, let serverWanted = event.wanted {
            if !unacknowledgedTransport || serverWanted == wanted {
                wanted = serverWanted
                unacknowledgedTransport = false
            }
        }
        if event.committed == true, let target = event.target {
            commit?(target)
            pending = nil
            requestID = nil
        } else if event.state == "rejected" {
            pending = nil
            requestID = nil
        }
        return true
    }
}
