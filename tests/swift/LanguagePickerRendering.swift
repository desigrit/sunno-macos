import AppKit
import SwiftUI

@main
struct LanguagePickerRendering {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try checkScripts(output)
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

    @MainActor static func checkScripts(_ output: URL) throws {
        let phrases = [["مرحبا", " بكم"], ["今天", "有字幕。"], ["今日", "は晴れです。"]]
        let lines = phrases.enumerated().map { index, words in
            CaptionLine(utteranceId: index, generation: 0, text: words.joined(), speakerId: nil,
                        isFinal: true, clarity: nil, words: words.map { .init(text: $0, probability: 0.95) },
                        startedAt: nil, frozenSpeaker: nil)
        }
        let view = NSHostingView(rootView: VStack(alignment: .leading) {
            ForEach(lines) { line in
                CaptionTextView(line: line, fontSize: 22, opacity: 1).frame(maxWidth: .infinity)
            }
        }.padding(8).frame(width: 270, height: 125).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 270, height: 125),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        func textViews(_ node: NSView) -> [WordHoverTextView] {
            if let text = node as? WordHoverTextView { return [text] }
            return node.subviews.flatMap(textViews)
        }
        let rendered = textViews(view)
        guard Set(rendered.map(\.string)) == Set(lines.map(\.text)),
              let arabic = rendered.first(where: { $0.string == lines[0].text }),
              let layout = arabic.layoutManager, let container = arabic.textContainer else {
            throw CocoaError(.coderInvalidValue)
        }
        layout.ensureLayout(for: container)
        func wordX(_ index: Int) -> CGFloat {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container).midX
        }
        guard wordX(0) > wordX((arabic.string as NSString).length - 1),
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try png.write(to: output.appendingPathComponent("caption-scripts.png"))
        window.orderOut(nil)
    }
}

