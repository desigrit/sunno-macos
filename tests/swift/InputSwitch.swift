import Foundation

@main
struct InputChecks {
    static func main() { MainActor.assumeIsolated { checks() } }
}

@MainActor
private func checks() {
    var count = 0
    func expect(_ condition: Bool, _ description: String) {
        precondition(condition, description)
        count += 1
        print("PASS \(description)")
    }
    func event(_ object: [String: Any]) -> BackendEvent {
        try! JSONDecoder().decode(BackendEvent.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func targetWire(_ target: AudioInputTarget) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as! [String: Any]
    }
    let a = AudioInputTarget(kind: "microphone", endpointID: "a", name: "Microphone", index: 1, followDefault: false)
    let b = AudioInputTarget(kind: "microphone", endpointID: "b", name: "Microphone", index: 2, followDefault: false)
    let inputs = InputSwitch()
    var sent: [BackendCommand] = []
    var committed: [AudioInputTarget] = []
    inputs.send = { sent.append($0); return true }
    inputs.commit = { committed.append($0) }
    inputs.request(a)
    let oldID = inputs.requestID!
    inputs.request(b)
    let newID = inputs.requestID!
    expect(committed.isEmpty, "selection does not save preferences before acknowledgement")
    expect(!inputs.apply(event(["type": "input", "state": "ready", "request_id": oldID,
                               "target": targetWire(a), "committed": true])),
           "superseded acknowledgements cannot commit an older selection")
    expect(inputs.apply(event(["type": "input", "state": "ready", "request_id": newID,
                               "target": targetWire(b), "wanted": true, "running": true, "committed": true])),
           "latest selection acknowledgement is accepted")
    expect(committed == [b] && inputs.pending == nil, "only confirmed capture commits the stable UID")
    inputs.setRunning(false)
    inputs.request(a)
    let pausedID = inputs.requestID!
    _ = inputs.apply(event(["type": "input", "state": "selected", "request_id": pausedID,
                          "target": targetWire(a), "wanted": false, "running": false, "committed": true]))
    expect(!inputs.wanted, "changing input while paused cannot resume capture")
    inputs.request(b)
    let replayID = inputs.requestID!
    inputs.reconnected()
    expect(inputs.requestID == replayID && inputs.pending == b, "reconnect replays the same idempotent request")
    expect(sent.contains { if case .stop = $0 { return true }; return false },
           "pause intent survives a reconnect")
    _ = inputs.apply(event(["type": "input", "state": "failed", "request_id": replayID,
                           "target": targetWire(a), "committed": true, "wanted": false, "running": false]))
    expect(committed.last == a && inputs.pending == nil, "failed switches restore the previous confirmed selection")
    let intent = inputs.nextIntent()
    _ = inputs.nextIntent()
    expect(!inputs.isCurrent(intent), "a late permission completion cannot supersede a newer user action")

    inputs.setRunning(true)
    inputs.suspend()
    _ = inputs.apply(event(["type": "input", "state": "stopped", "wanted": false, "running": false]))
    expect(inputs.wanted, "sleep suspends capture without forgetting the running intent")
    inputs.resume()
    _ = inputs.apply(event(["type": "input", "state": "stopped", "wanted": false, "running": false]))
    expect(inputs.wanted, "a delayed sleep acknowledgement cannot cancel wake recovery")
    _ = inputs.apply(event(["type": "input", "state": "ready", "wanted": true, "running": true]))
    inputs.setRunning(false)
    inputs.suspend()
    inputs.resume()
    expect(!inputs.wanted, "sleep and wake never resume a user-paused session")

    let store = TranscriptStore()
    store.apply(event(["type": "final", "id": 1, "text": "Keep this caption."]))
    store.apply(event(["type": "input", "state": "recovering", "wanted": true,
                      "running": false, "message": "Reconnecting the input."]))
    store.apply(event(["type": "status", "state": "recovering", "wanted": true, "running": false]))
    expect(store.lines.count == 1 && store.wantedRunning && !store.isRunning,
           "recovery retains captions and keeps pause available")
    expect(store.problem?.severity == .info, "automatic recovery is informational, not a fatal error")
    store.apply(event(["type": "input", "state": "ready", "wanted": true, "running": true]))
    expect(store.problem == nil && store.lines.count == 1, "healthy capture clears only the recovery notice")
    print("\(count) Swift input checks passed.")
}
