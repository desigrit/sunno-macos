import SwiftUI
import AppKit

/// Window level, minimum size and the two remembered geometries.
///
/// All of this is AppKit rather than SwiftUI because SwiftUI has no vocabulary for it. A
/// `WindowGroup` cannot float above other applications, cannot swap its minimum size, and
/// cannot keep two separate saved frames. Compact mode needs all three.
///
/// The rule the Windows build discovered and that is easy to get backwards: the minimum size
/// must be lowered BEFORE shrinking into compact, and raised only AFTER expanding out of it.
/// Set them in the other order and the window silently refuses the resize, because it is
/// still holding a minimum larger than the size being asked for.
@MainActor
final class WindowChrome: ObservableObject {

    /// Small enough to be a caption strip, large enough that the expand button and a few
    /// words still fit. Below this the mode stops being useful and starts being a puzzle.
    static let compactMinimum = NSSize(width: 360, height: 150)
    static let expandedMinimum = NSSize(width: 720, height: 420)

    private weak var window: NSWindow?
    private var settings: AppSettings?
    private var observer: NSObjectProtocol?

    func attach(to window: NSWindow, settings: AppSettings) {
        self.window = window
        self.settings = settings

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false

        apply(compact: settings.isCompact, remember: false)
        applyFloating(settings.alwaysOnTop || settings.isCompact)

        // Reduce Motion is a live setting, not a launch-time one. Someone turning it on
        // because an animation is making them ill should not have to restart the app that is
        // captioning their conversation to be rid of it.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak settings] _ in
            Task { @MainActor in
                settings?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func setCompact(_ compact: Bool) {
        guard let settings, settings.isCompact != compact else { return }
        rememberCurrentFrame()
        settings.isCompact = compact
        apply(compact: compact, remember: true)
        // Always on top for as long as compact lasts. A caption strip that sinks behind the
        // window you are reading is useless, so the preference is overridden while it is on
        // and restored when it ends.
        applyFloating(compact || settings.alwaysOnTop)
    }

    func setAlwaysOnTop(_ onTop: Bool) {
        guard let settings else { return }
        settings.alwaysOnTop = onTop
        applyFloating(onTop || settings.isCompact)
    }

    func rememberCurrentFrame() {
        guard let window, let settings else { return }
        settings.setFrame(window.frame, compact: settings.isCompact)
    }

    private func applyFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    private func apply(compact: Bool, remember: Bool) {
        guard let window, let settings else { return }

        // Lower the minimum first, then resize. See the type comment.
        window.contentMinSize = compact ? Self.compactMinimum : Self.expandedMinimum

        let saved = settings.frame(compact: compact)
        let target = saved ?? defaultFrame(compact: compact, on: window.screen)
        window.setFrame(target, display: true, animate: !settings.reduceMotion)

        // And raise it again once the window is actually the new size.
        window.contentMinSize = compact ? Self.compactMinimum : Self.expandedMinimum
    }

    private func defaultFrame(compact: Bool, on screen: NSScreen?) -> NSRect {
        let visible = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = compact
            ? NSSize(width: 460, height: 200)
            : NSSize(width: 1040, height: 660)

        if compact {
            // Bottom centre, out of the way of what is being read above it.
            return NSRect(
                x: visible.midX - size.width / 2,
                y: visible.minY + 80,
                width: size.width, height: size.height)
        }
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width, height: size.height)
    }
}

/// Hands the hosting `NSWindow` to the chrome controller.
///
/// SwiftUI on macOS 13 has no supported way to reach its own window, so this rides along in
/// the view tree and reports upward the first time it is placed.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
