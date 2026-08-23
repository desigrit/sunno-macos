import SwiftUI
import AppKit

/// One caption's text, rendered by AppKit rather than SwiftUI.
///
/// This is the one place in the app that does not use a SwiftUI `Text`, and the reason is a
/// shipped feature rather than taste. Words the model was unsure about are styled
/// individually, and hovering one shows how confident it was. SwiftUI can do the styling
/// through `AttributedString`, but it cannot map a pointer location back to the word under
/// it, so the hover half is simply unavailable. `NSTextView` exposes
/// `characterIndexForInsertion(at:)`, which is the AppKit spelling of the
/// `GetPositionFromPoint` call the Windows build relies on for exactly this.
///
/// Three signals mark an uncertain word, not one: grey, italic, and an underline. That is
/// carried over deliberately. Colour alone would fail Differentiate Without Color, and this
/// is the last app that should lean on hue to carry meaning.
struct CaptionTextView: NSViewRepresentable {

    let line: CaptionLine
    let fontSize: CGFloat
    let opacity: Double

    func makeNSView(context: Context) -> NSTextView {
        let view = WordHoverTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard let hoverView = view as? WordHoverTextView else { return }
        hoverView.words = line.words
        hoverView.textStorage?.setAttributedString(attributed())
        hoverView.alphaValue = opacity
        hoverView.rebuildTooltips()
    }

    /// Builds the styled string, and records where each word landed so the hover can find it.
    private func attributed() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: fontSize)
        let result = NSMutableAttributedString()

        // No word scores: provisional text, or an engine that reports none. The streaming
        // transducers are in the second group by design, so this is the common path rather
        // than a fallback.
        guard !line.words.isEmpty else {
            return NSAttributedString(string: line.text, attributes: [
                .font: body,
                .foregroundColor: NSColor.labelColor,
            ])
        }

        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)

        for word in line.words {
            // faster-whisper prefixes each word with the space that preceded it, so styling
            // the raw token would underline the gap in front of the word as well.
            let raw = word.text
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let leading = String(raw.prefix(while: { $0 == " " }))

            if !leading.isEmpty {
                result.append(NSAttributedString(string: leading, attributes: [.font: body]))
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: word.isUncertain ? italic : body,
                .foregroundColor: word.isUncertain
                    ? NSColor.secondaryLabelColor
                    : NSColor.labelColor,
            ]
            if word.isUncertain {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: trimmed, attributes: attributes))
        }

        return result
    }
}

/// An `NSTextView` that can say which word is under the pointer.
///
/// Tooltips are attached per word rather than computed in `mouseMoved`, because AppKit
/// already owns the timing: it decides when a pointer has rested long enough to mean
/// something, and it matches the delay of every other tooltip on the system. Reimplementing
/// that with a timer produces something that feels almost right, which is worse.
final class WordHoverTextView: NSTextView {

    var words: [CaptionLine.WordScore] = []

    /// Rebuilds one tooltip rectangle per uncertain word.
    ///
    /// Only the uncertain ones. A tooltip on every word turns reading into a minefield of
    /// popups, and the confident ones have nothing to say: they sit at 0.97 to 1.00 and the
    /// number is noise. This mirrors the Windows build, which tiles hover ranges across the
    /// whole line but only styles and explains the words below the threshold.
    func rebuildTooltips() {
        removeAllToolTips()
        guard !words.isEmpty,
              let layoutManager = layoutManager,
              let container = textContainer else { return }

        var cursor = 0
        for word in words {
            let raw = word.text
            let leading = raw.prefix(while: { $0 == " " }).count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let start = cursor + leading
            let length = trimmed.utf16.count
            cursor = start + length

            guard word.isUncertain, length > 0 else { continue }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: start, length: length),
                actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)

            let percent = Int((word.probability * 100).rounded())
            addToolTip(rect, owner: "Heard with \(percent)% confidence", userData: nil)
        }
    }
}
