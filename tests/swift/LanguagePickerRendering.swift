import AppKit
import SwiftUI

@main
struct LanguagePickerRendering {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: VStack(spacing: 0) {
                LanguageChoiceRow(title: "Spoken language", codes: ["auto","en","es","ja"],
                                  selected: "auto", detected: "es", choose: { _ in })
                LanguageChoiceRow(title: "Translate to", codes: ["off","pt"], selected: "pt", choose: { _ in })
            }.frame(width: 232).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 232, height: 64),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CocoaError(.coderInvalidValue)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 500 else {
                throw CocoaError(.coderInvalidValue)
            }
            try png.write(to: output.appendingPathComponent("languages-\(mode).png"))
            window.orderOut(nil)
        }
    }
}

