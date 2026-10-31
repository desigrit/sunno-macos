import AppKit
import Combine
import Sparkle

/// Manual GitHub updates. Sparkle owns signature verification, installation and relaunch.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let releasesURL = URL(string: "https://github.com/desigrit/sunno-macos/releases")!
    static let feedURL = "https://github.com/desigrit/sunno-macos/releases/latest/download/appcast.xml"

    @Published private(set) var status = ""
    @Published private(set) var isChecking = false
    var recordingIsBusy: () -> Bool = { false }
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?

    func checkForUpdates() {
        guard !isChecking else { return }
        guard !recordingIsBusy() else {
            status = "Stop your recording before updating Sunno."
            return
        }
        if controller == nil {
            let created = SPUStandardUpdaterController(startingUpdater: false,
                                                       updaterDelegate: self, userDriverDelegate: nil)
            created.updater.automaticallyChecksForUpdates = false
            created.updater.automaticallyDownloadsUpdates = false
            created.updater.sendsSystemProfile = false
            do { try created.updater.start() }
            catch {
                status = "Updates are unavailable in this build. Download Sunno from GitHub releases."
                return
            }
            controller = created
        }
        status = "Checking GitHub for updates..."
        isChecking = true
        controller?.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Sunno \(item.displayVersionString) is available. Continue in the update window."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = Self.noUpdateMessage(error as NSError)
    }

    static func noUpdateMessage(_ error: NSError) -> String {
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        switch reason {
        case SPUNoUpdateFoundReason.onLatestVersion.rawValue,
             SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue:
            return "You're up to date."
        case SPUNoUpdateFoundReason.systemIsTooOld.rawValue:
            return "The latest Sunno update requires a newer version of macOS."
        case SPUNoUpdateFoundReason.systemIsTooNew.rawValue,
             SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue:
            return "The latest Sunno update is not compatible with this Mac."
        default:
            return "No compatible update was found. View GitHub releases for details."
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isChecking = false
        if let error {
            let failure = error as NSError
            if failure.domain == SUSparkleErrorDomain && failure.code == SUError.noUpdateError.rawValue {
                return
            }
            if failure.domain == SUSparkleErrorDomain && failure.code == SUError.installationCanceledError.rawValue {
                status = "Update cancelled. You can try again whenever you're ready."
            } else {
                status = "Could not finish the update check. Try again or open GitHub releases."
            }
        }
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        status = "Download cancelled. You can try again whenever you're ready."
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        deferInstallationIfRecording(installHandler)
    }

    func deferInstallationIfRecording(_ installHandler: @escaping () -> Void) -> Bool {
        guard recordingIsBusy() else { return false }
        pendingInstall = installHandler
        status = "The update is ready. Stop your recording to finish installing it."
        return true
    }

    func recordingStateChanged() {
        guard !recordingIsBusy(), let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }
}
