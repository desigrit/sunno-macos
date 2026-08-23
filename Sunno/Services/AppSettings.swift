import Foundation
import SwiftUI
import AppKit

/// Preferences, and the two window geometries.
///
/// Stored in UserDefaults rather than a JSON file beside the model cache. The Windows build
/// hand-rolls a settings file because WinUI has no equivalent; macOS does, it is backed up
/// and migrated by the system, and a hand-rolled file would be a worse version of it.
///
/// Compact and expanded geometry are remembered separately, and that is a real requirement
/// rather than a nicety: the two modes are used in different places on the screen and at very
/// different sizes, and collapsing them to one frame means every switch moves the window to
/// somewhere the user did not leave it.
@MainActor
final class AppSettings: ObservableObject {

    private let defaults = UserDefaults.standard

    @Published var showClarity: Bool {
        didSet { defaults.set(showClarity, forKey: Keys.showClarity) }
    }

    @Published var forceCPU: Bool {
        didSet { defaults.set(forceCPU, forKey: Keys.forceCPU) }
    }

    @Published var captionFontSize: CGFloat {
        didSet { defaults.set(Double(captionFontSize), forKey: Keys.captionFontSize) }
    }

    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Keys.alwaysOnTop) }
    }

    @Published var isCompact: Bool {
        didSet { defaults.set(isCompact, forKey: Keys.isCompact) }
    }

    @Published var selectedModel: String? {
        didSet { defaults.set(selectedModel, forKey: Keys.selectedModel) }
    }

    /// The capture device, remembered across launches.
    ///
    /// The index alone is not enough and the Windows build learned this the hard way
    /// (`MainWindow.xaml.cs:2491-2619`): indices are positional, so plugging in an interface
    /// renumbers everything after it and the saved index silently selects a different device.
    /// The name is what identifies it; the index is only a hint about where to look first.
    @Published var deviceIndex: Int? {
        didSet { defaults.set(deviceIndex ?? -1, forKey: Keys.deviceIndex) }
    }

    /// Held to re-find the device, and never written to a log or the diagnostics export:
    /// "Headset (R-Phonak hearing aid)" is health information arriving through a field nobody
    /// thinks of as sensitive.
    @Published var deviceName: String? {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName) }
    }

    /// Whether the remembered device is a system-audio source rather than a microphone. Kept
    /// separately because the two are passed to the engine as different arguments.
    @Published var deviceIsLoopback: Bool {
        didSet { defaults.set(deviceIsLoopback, forKey: Keys.deviceIsLoopback) }
    }

    /// Whether the user has ever finished setup on this machine. Absent means a genuine first
    /// run, which is what lets the app open straight onto the model picker instead of showing
    /// a window it cannot use yet.
    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Keys.hasCompletedSetup) }
    }

    /// Whether the app has already explained why system audio needs the screen recording
    /// permission. Shown once, because a warning repeated on every use stops being read.
    @Published var hasSeenScreenCaptureExplanation: Bool {
        didSet { defaults.set(hasSeenScreenCaptureExplanation,
                              forKey: Keys.hasSeenScreenCaptureExplanation) }
    }

    /// Mirrors the system setting so views can branch without each one asking AppKit.
    /// Refreshed by `WindowChrome`, which is already observing the notification.
    @Published var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    static let fontSizes: [CGFloat] = [15, 17, 20, 24, 28, 34, 40]

    init() {
        showClarity = defaults.object(forKey: Keys.showClarity) as? Bool ?? true
        forceCPU = defaults.bool(forKey: Keys.forceCPU)
        let size = defaults.double(forKey: Keys.captionFontSize)
        captionFontSize = size > 0 ? CGFloat(size) : 20
        alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? false
        isCompact = defaults.bool(forKey: Keys.isCompact)
        selectedModel = defaults.string(forKey: Keys.selectedModel)
        let savedIndex = defaults.object(forKey: Keys.deviceIndex) as? Int ?? -1
        deviceIndex = savedIndex >= 0 ? savedIndex : nil
        deviceName = defaults.string(forKey: Keys.deviceName)
        deviceIsLoopback = defaults.bool(forKey: Keys.deviceIsLoopback)
        hasCompletedSetup = defaults.bool(forKey: Keys.hasCompletedSetup)
        hasSeenScreenCaptureExplanation =
            defaults.bool(forKey: Keys.hasSeenScreenCaptureExplanation)
    }

    func stepFontSize(by delta: Int) {
        let sizes = Self.fontSizes
        let current = sizes.firstIndex(of: captionFontSize)
            ?? sizes.firstIndex(where: { $0 >= captionFontSize })
            ?? 2
        let next = min(max(current + delta, 0), sizes.count - 1)
        captionFontSize = sizes[next]
    }

    // MARK: - Window frames

    func frame(compact: Bool) -> NSRect? {
        let key = compact ? Keys.compactFrame : Keys.expandedFrame
        guard let raw = defaults.string(forKey: key), !raw.isEmpty else { return nil }
        let rect = NSRectFromString(raw)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    func setFrame(_ rect: NSRect, compact: Bool) {
        defaults.set(NSStringFromRect(rect), forKey: compact ? Keys.compactFrame : Keys.expandedFrame)
    }

    private enum Keys {
        static let showClarity = "showClarity"
        static let forceCPU = "forceCPU"
        static let captionFontSize = "captionFontSize"
        static let alwaysOnTop = "alwaysOnTop"
        static let isCompact = "compactMode"
        static let selectedModel = "selectedModel"
        static let deviceIndex = "deviceIndex"
        static let deviceName = "deviceName"
        static let deviceIsLoopback = "deviceIsLoopback"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let hasSeenScreenCaptureExplanation = "hasSeenScreenCaptureExplanation"
        static let compactFrame = "compactFrame"
        static let expandedFrame = "expandedFrame"
    }
}
