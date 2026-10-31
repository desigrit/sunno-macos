import AppKit
import Sparkle

@main
struct AppUpdaterChecks {
    static func main() { MainActor.assumeIsolated { check() } }

    @MainActor static func check() {
        _ = NSApplication.shared
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            count += 1
            print("PASS \(message)")
        }
        let subject = AppUpdater()
        expect(subject.status.isEmpty && !subject.isChecking, "startup does not check or create a session")
        var busy = true
        subject.recordingIsBusy = { busy }
        subject.checkForUpdates()
        expect(!subject.isChecking && subject.status.contains("recording"), "recording blocks a new update check")
        var installed = 0
        expect(subject.deferInstallationIfRecording { installed += 1 }, "recording postpones relaunch")
        subject.recordingStateChanged()
        expect(installed == 0, "saving or recording keeps the update waiting")
        busy = false
        subject.recordingStateChanged()
        subject.recordingStateChanged()
        expect(installed == 1, "finishing recording resumes the update exactly once")
        expect(!subject.deferInstallationIfRecording { installed += 1 }, "idle app lets Sparkle install normally")
        expect(installed == 1, "idle path does not invoke Sparkle's handler twice")

        func noUpdate(_ reason: SPUNoUpdateFoundReason) -> NSError {
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                    userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
        }
        expect(AppUpdater.noUpdateMessage(noUpdate(.onLatestVersion)) == "You're up to date.", "latest version status")
        expect(AppUpdater.noUpdateMessage(noUpdate(.onNewerThanLatestVersion)) == "You're up to date.", "local newer build avoids downgrades")
        expect(AppUpdater.noUpdateMessage(noUpdate(.systemIsTooOld)).contains("newer version of macOS"), "OS incompatibility is not called up to date")
        expect(AppUpdater.noUpdateMessage(noUpdate(.hardwareDoesNotSupportARM64)).contains("not compatible"), "hardware incompatibility is explained")
        expect(AppUpdater.noUpdateMessage(noUpdate(.unknown)).contains("No compatible update"), "unknown reason does not claim latest")

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        subject.updaterDidNotFindUpdate(updater, error: noUpdate(.systemIsTooOld))
        subject.updater(updater, didFinishUpdateCycleFor: .updates, error: noUpdate(.systemIsTooOld))
        expect(!subject.isChecking && subject.status.contains("newer version of macOS"), "cycle finish preserves compatibility explanation")
        subject.userDidCancelDownload(updater)
        subject.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        expect(subject.status.contains("cancelled") && !subject.isChecking, "cancellation allows retry")
        subject.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: NSURLErrorDomain, code: -1009))
        expect(subject.status.contains("Try again"), "offline error allows retry")
        print("\(count) updater checks passed.")
    }
}
