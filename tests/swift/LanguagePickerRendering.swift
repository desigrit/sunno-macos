import AppKit
import SwiftUI

private final class DisclosureState: ObservableObject {
    @Published var expanded = false
    var measuredHeight: CGFloat = 0
}

private struct LanguageSectionFixture: View {
    @ObservedObject var state: DisclosureState
    let store: TranscriptStore

    var body: some View {
        SidebarLanguageSection(store: store, isExpanded: $state.expanded, reduceMotion: true,
                               onLanguage: { _ in }, onTranslate: { _ in })
            .background(GeometryReader { proxy in
                Color.clear.onAppear { state.measuredHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { state.measuredHeight = $0 }
            })
            .frame(width: 232, height: 140, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct LanguagePickerRendering {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try checkScripts(output)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let store = TranscriptStore()
            for json in [
                #"{"type":"spoken_language","choices":["auto","en","es","ja"],"selected":"auto","detected":"es"}"#,
                #"{"type":"translation_state","choices":["off","pt"],"selected":"pt","phase":"ready"}"#,
            ] {
                store.apply(try JSONDecoder().decode(BackendEvent.self, from: Data(json.utf8)))
            }
            let state = DisclosureState()
            let view = NSHostingView(rootView: LanguageSectionFixture(state: state, store: store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 232, height: 140),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            func settle() {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
                view.layoutSubtreeIfNeeded()
            }
            func clickHeader() throws {
                let point = NSPoint(x: view.bounds.midX, y: view.bounds.height - 16)
                func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw CocoaError(.coderInvalidValue) }
                    return event
                }
                NSApp.postEvent(try mouse(.leftMouseUp), atStart: true)
                window.sendEvent(try mouse(.leftMouseDown))
                if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                    window.sendEvent(up)
                }
                settle()
            }
            func capture(_ name: String) throws {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw CocoaError(.coderInvalidValue)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 500 else {
                    throw CocoaError(.coderInvalidValue)
                }
                try png.write(to: output.appendingPathComponent(name))
            }
            settle()
            let closedHeight = state.measuredHeight
            precondition(!state.expanded && closedHeight > 0 && closedHeight <= 42, "Language starts in one compact row")
            try capture("language-collapsed-\(mode).png")
            try clickHeader()
            precondition(state.expanded && state.measuredHeight >= closedHeight + 50, "Clicking the header reveals both pickers")
            try capture("languages-\(mode).png")
            try clickHeader()
            precondition(!state.expanded && state.measuredHeight == closedHeight, "A second click reclaims the space")
            precondition(store.detectedLanguage == "es" && store.translationTarget == "pt", "Folding preserves the choices")
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

