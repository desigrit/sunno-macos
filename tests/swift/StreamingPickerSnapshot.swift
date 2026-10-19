// Render just the picker in an isolated process. No backend, capture or preferences writes.
import AppKit
import SwiftUI

@main
struct StreamingPickerSnapshot {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = TranscriptStore()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "Sunno.StreamingSnapshot")!)
        let names = ["Whisper large-v3", "Distil-Whisper large-v3", "Whisper medium", "Whisper small",
                     "Whisper base", "Zipformer", "Kroko", "Apple Speech", "Apple Speech + Whisper"]
        let entries: [[String: Any]] = names.enumerated().map { index, name in
            ["id": index == 7 ? "apple-speech" : index == 8 ? "apple-speech-whisper" : String(index),
             "name": name, "detail": index == 8 ? "Live English captions, then large-v3 corrections. Uses more memory and power."
                : index == 7 ? "On-device English streaming. Delay not measured yet." : "Existing speech model",
             "approx_mb": index == 7 ? 0 : 3090, "languages": "English", "available": index < 7,
             "lag_ms": 0, "lag_text": "Not measured yet", "responsive": false, "auto_select": false]
        }
        let data = try JSONSerialization.data(withJSONObject: ["type": "model_catalog", "catalog": entries])
        store.apply(try JSONDecoder().decode(BackendEvent.self, from: data))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = SidebarView(store: store, settings: settings, onRename: { _ in }, onDelete: { _ in },
                onSelectModel: { _ in }, pendingModel: nil, onRefreshModels: {}, modelSectionOpen: true)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            func scrollToModels(_ view: NSView) {
                if let scroll = view as? NSScrollView, let doc = scroll.documentView,
                   doc.bounds.height > scroll.contentView.bounds.height {
                    doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - scroll.contentView.bounds.height)))
                }
                view.subviews.forEach(scrollToModels)
            }
            scrollToModels(host)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // SwiftUI's cached display has transparent backing outside the native List.
            // Composite only this view onto the window color; never capture the desktop.
            let snapshot = NSImage(size: host.bounds.size)
            snapshot.lockFocus()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                host.bounds.fill()
            }
            bitmap.draw(in: host.bounds)
            snapshot.unlockFocus()
            let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("picker-\(name).png")
            try NSBitmapImageRep(data: snapshot.tiffRepresentation!)!
                .representation(using: .png, properties: [:])!.write(to: output)
            print(output.path)
            window.orderOut(nil)
        }
    }
}
