// The transcript's line identity, exercised across an engine restart.
//
// The bug this exists for: the engine numbers utterances from zero and restarts that counter
// with every process, while the client keyed its lines on that number alone. Switching to
// system audio -- or changing microphone, or changing model -- restarts the engine, so its
// first utterance matched the transcript's oldest line and overwrote it. What that looks like
// from the outside is new speech appearing at the *top* and the conversation being eaten from
// the beginning.
//
// Run through tests/test_transcript_order.py, which compiles this against the real store.

import Foundation

@MainActor
func decode(_ json: String) -> BackendEvent {
    try! JSONDecoder().decode(BackendEvent.self, from: Data(json.utf8))
}

@main
struct TranscriptOrderChecks {
    static func main() {
        MainActor.assumeIsolated { check() }
    }
}

@MainActor
func check() {
    let store = TranscriptStore()
    var failures: [String] = []

    // Engine one: three utterances, ids 1..3 -- what a microphone session produces.
    store.beginEngineSession()
    for (id, text) in [(1, "one"), (2, "two"), (3, "three")] {
        store.apply(decode("""
        {"type":"final","id":\(id),"text":"\(text)","speaker_id":0}
        """))
    }
    print("after engine 1: \(store.lines.map(\.text))")
    if store.lines.map(\.text) != ["one", "two", "three"] {
        failures.append("engine 1 did not append in order")
    }

    // The engine restarts -- switching to system audio, a new microphone, a new model. The
    // pipeline counts from zero again, so the ids repeat.
    store.beginEngineSession()
    for (id, text) in [(1, "four"), (2, "five")] {
        store.apply(decode("""
        {"type":"final","id":\(id),"text":"\(text)","speaker_id":0}
        """))
    }
    print("after engine 2: \(store.lines.map(\.text))")

    let expected = ["one", "two", "three", "four", "five"]
    if store.lines.map(\.text) != expected {
        failures.append("a restart overwrote earlier lines: got \(store.lines.map(\.text))")
    }
    if Set(store.lines.map(\.id)).count != store.lines.count {
        failures.append("two lines share an identity, which breaks ForEach")
    }

    // A partial still finalises in place within one engine session.
    store.apply(decode("{\"type\":\"partial\",\"id\":3,\"text\":\"six...\",\"speaker_id\":0}"))
    store.apply(decode("{\"type\":\"final\",\"id\":3,\"text\":\"six\",\"speaker_id\":0}"))
    print("after a partial then final: \(store.lines.map(\.text))")
    if store.lines.map(\.text) != expected + ["six"] {
        failures.append("a partial and its final did not collapse into one line")
    }

    // A discard only removes a provisional from the current session.
    store.apply(decode("{\"type\":\"partial\",\"id\":9,\"text\":\"gone...\",\"speaker_id\":0}"))
    store.apply(decode("{\"type\":\"discard\",\"id\":9}"))
    if store.lines.contains(where: { $0.text == "gone..." }) {
        failures.append("discard did not remove the provisional")
    }
    // ...and must not reach into an older session's line with the same id.
    store.apply(decode("{\"type\":\"discard\",\"id\":1}"))
    if !store.lines.contains(where: { $0.text == "one" }) {
        failures.append("discard reached back into a previous engine session")
    }

    print()
    if failures.isEmpty {
        print("ALL PASS")
    } else {
        print("FAILURES:")
        failures.forEach { print("  - \($0)") }
        exit(1)
    }
}

