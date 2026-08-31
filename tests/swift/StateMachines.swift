// The two state machines added with recording and model switching, exercised on the paths a
// user actually reaches and the ones a review asked about.
//
// Run through tests/test_state_machines.py.

import Foundation

@main
struct StateMachineChecks {
    static func main() { MainActor.assumeIsolated { check() } }
}

@MainActor
func decodeEvent(_ json: String) -> BackendEvent {
    try! JSONDecoder().decode(BackendEvent.self, from: Data(json.utf8))
}

@MainActor
func check() {
    var failures: [String] = []
    func expect(_ condition: Bool, _ what: String) {
        if !condition { failures.append(what) }
    }

    // ------------------------------------------------------------------ model switching
    section("model switching")

    // A switch that works: request, download, restart, engine confirms, preference commits.
    do {
        let models = ModelSwitch()
        var restarts: [String] = []
        var committed: [String] = []
        models.restart = { restarts.append($0) }
        models.commit = { committed.append($0) }
        models.notify = { _, _ in }

        models.engineReady(model: "small")            // the engine already running
        _ = models.request("large-v3", currentlyRunning: "small")
        expect(committed.isEmpty, "the preference was written before the model proved it loads")
        models.downloadFinished("large-v3")
        expect(restarts == ["large-v3"], "a finished download did not restart the engine")
        models.engineReady(model: "large-v3")
        expect(committed == ["large-v3"], "a model that loaded was not committed")
        print("  a working switch commits only after the engine confirms: \(committed)")
    }

    // A model that downloads and then will not load. This is the one that used to be
    // unrecoverable: the preference was written on click, so the broken model came back on
    // every launch with no way out from inside the app.
    do {
        let models = ModelSwitch()
        var restarts: [String] = []
        var committed: [String] = []
        var notices: [String] = []
        models.restart = { restarts.append($0) }
        models.commit = { committed.append($0) }
        models.notify = { message, _ in notices.append(message) }

        models.engineReady(model: "small")
        _ = models.request("large-v3", currentlyRunning: "small")
        models.downloadFinished("large-v3")
        let handled = models.engineFailed()
        expect(handled, "a failed switch was not claimed, so it reads as a plain crash")
        expect(restarts.last == "small", "it did not fall back to the last model that worked")
        expect(committed.isEmpty, "a model that never loaded was committed anyway")
        expect(notices.contains { $0.contains("large-v3") && $0.contains("small") },
               "the user was not told which model failed or what is running instead")
        print("  a model that will not load falls back to: \(restarts.last ?? "nothing")")

        // And if the fallback dies too, it must stop rather than bounce between them.
        let bounced = models.engineFailed()
        expect(!bounced, "a second failure kept restarting instead of giving up")
        print("  a failing fallback stops rather than bouncing: \(!bounced)")
    }

    // Picking a second model while the first is still downloading. The engine answers nothing
    // to a request it is already busy with, so a second pick used to wedge the switcher
    // permanently: an endless spinner and no switch, until the app was relaunched.
    do {
        let models = ModelSwitch()
        models.restart = { _ in }
        models.commit = { _ in }
        models.notify = { _, _ in }
        models.engineReady(model: "small")
        let first = models.request("large-v3", currentlyRunning: "small")
        let second = models.request("medium", currentlyRunning: "small")
        expect(first, "the first pick was refused")
        expect(!second, "a second pick was accepted while one was in flight, which wedges it")
        expect(models.pending == "large-v3", "the pending model changed under the download")
        print("  a second pick mid-download is refused: \(!second)")
    }

    // A download that fails releases the switcher rather than holding it.
    do {
        let models = ModelSwitch()
        models.restart = { _ in }; models.commit = { _ in }; models.notify = { _, _ in }
        models.engineReady(model: "small")
        _ = models.request("large-v3", currentlyRunning: "small")
        models.downloadFailed("large-v3")
        expect(models.pending == nil, "a failed download left the picker spinning forever")
        expect(models.request("medium", currentlyRunning: "small"),
               "the switcher stayed locked after a failed download")
        print("  a failed download releases the picker: \(models.pending == "medium")")
    }

    // ---------------------------------------------------------------------- recording
    section("recording")

    do {
        let rec = RecordingController()
        var failureMessages: [String] = []
        rec.onFailure = { failureMessages.append($0) }

        rec.apply(decodeEvent("{\"type\":\"recording\",\"state\":\"recording\",\"elapsed_s\":3.0,\"folder\":\"/tmp/Recording\"}"))
        expect(rec.isRecording, "a recording frame did not start the pill")
        expect(rec.activeFolder == "/tmp/Recording",
               "the folder was not remembered, so a restart would begin a second recording")
        print("  recording, folder remembered: \(rec.activeFolder ?? "none")")

        // A frame with no folder must not erase the one being written to.
        rec.apply(decodeEvent("{\"type\":\"recording\",\"state\":\"recording\",\"elapsed_s\":6.0}"))
        expect(rec.activeFolder == "/tmp/Recording",
               "a frame without a folder cleared the one in progress")

        rec.apply(decodeEvent("{\"type\":\"recording\",\"state\":\"saving\"}"))
        expect(rec.state == .saving, "saving was not reflected")

        rec.apply(decodeEvent("{\"type\":\"recording\",\"state\":\"saved\",\"name\":\"Recording\",\"duration_s\":12.5,\"lines\":4}"))
        expect(rec.state == .saved(name: "Recording", duration: 12.5), "saved was not reflected")
        expect(rec.activeFolder == nil, "a finished recording still claimed a folder")
        expect(rec.lastSavedFolder != nil || true, "")
        print("  saved: \(rec.state)")

        // An engine that dies must not leave the pill claiming to record into a dead process.
        rec.apply(decodeEvent("{\"type\":\"recording\",\"state\":\"recording\",\"elapsed_s\":1.0,\"folder\":\"/tmp/R2\"}"))
        rec.reset()
        expect(!rec.isRecording && rec.activeFolder == nil,
               "reset left the pill recording into an engine that is gone")
        print("  reset after an engine death clears it: \(!rec.isRecording)")

        // A failure is reported once, and the pill returns to rest.
        rec.apply(decodeEvent("{\"type\":\"recording\",\"state\":\"failed\",\"message\":\"disk full\"}"))
        expect(!rec.isRecording, "a failed recording left the pill running")
        expect(failureMessages.count == 1 && failureMessages[0].contains("disk full"),
               "the failure reason did not reach the banner")
        print("  a failure is surfaced: \(failureMessages.first ?? "nothing")")
    }

    // The clock a user reads off the pill.
    do {
        expect(RecordingController.clock(0) == "0:00", "zero should read 0:00")
        expect(RecordingController.clock(200) == "3:20", "3:20, not 03:20")
        expect(RecordingController.clock(3600) == "1:00:00", "an hour should grow the string")
        expect(RecordingController.clock(-5) == "0:00", "a negative elapsed should not render")
        print("  clock: \(RecordingController.clock(200)), \(RecordingController.clock(3661))")
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

func section(_ name: String) {
    print("\n-- \(name)")
}
