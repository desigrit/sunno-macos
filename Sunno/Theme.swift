import SwiftUI
import AppKit

/// The palette, carried over from `app/App.xaml` unchanged.
///
/// Two rules from the Windows build survive the port intact, and both are decisions rather
/// than defaults.
///
/// The brand ink is deliberately NOT the system accent colour. It is the same mark as the app
/// icon, and an icon that recolours itself per machine stops being an identity. Everything
/// else follows the system: `NSColor.controlAccentColor` for selection and the primary
/// action, semantic colours for text and surfaces, so the app tracks light, dark and
/// Increase Contrast without being asked.
///
/// The speaker palette is eight mid-tone hues chosen to stay legible on both light and dark
/// backgrounds. It is indexed modulo 8, so a ninth speaker reuses the first colour rather
/// than falling off the end.
///
/// `tests/test_theme_parity.py` reads these hex values back out and compares them against
/// App.xaml, because they were transcribed by hand and a single wrong digit is the kind of
/// thing nobody notices until two people are the same colour.
enum Theme {

    // MARK: - Brand

    /// #1F8A70 in light, #42B795 in dark. Lifted on dark, where the light value goes muddy.
    static let ink = dynamic(light: 0x1F8A70, dark: 0x42B795)

    /// The same ink at low opacity, for the "In use" and "Downloaded" badges. A solid fill
    /// with white text measures 4.26:1 in light theme, under the 4.5:1 a small bold label
    /// needs, and this is the last app that should ship a contrast shortfall.
    static let inkSubtle = dynamic(light: 0x1F8A70, dark: 0x42B795, lightAlpha: 0.16, darkAlpha: 0.22)

    // MARK: - Speakers

    private static let speakerHexes: [Int] = [
        0x2AA198, 0x4C8DDA, 0xD08442, 0xA672D0,
        0xD169B5, 0x6FA33C, 0xD9534F, 0xC9A227,
    ]

    /// Indexed modulo 8, matching `MainWindow.SpeakerBrush`.
    static func speaker(_ index: Int) -> Color {
        let wrapped = ((index % speakerHexes.count) + speakerHexes.count) % speakerHexes.count
        return Color(hex: speakerHexes[wrapped])
    }

    static var speakerCount: Int { speakerHexes.count }

    // MARK: - Clarity

    static let clarityGood = Color(hex: 0x2E8B57)
    static let clarityMid  = Color(hex: 0xB26A00)
    static let clarityLow  = Color(hex: 0xC42B1C)

    /// Thresholds from `MainWindow.ClarityBrush`: 80 and above is good, 55 and above is mid.
    static func clarityColor(_ clarity: Int?) -> Color {
        guard let clarity else { return clarityLow }
        if clarity >= 80 { return clarityGood }
        if clarity >= 55 { return clarityMid }
        return clarityLow
    }

    // MARK: - Caption rendering

    /// From `MainWindow.LineOpacity`. Own lines step back so the people you are trying to
    /// follow stay dominant; provisional text is dimmer still until it is replaced.
    static func lineOpacity(isFinal: Bool, isSelf: Bool) -> Double {
        if isSelf { return isFinal ? 0.55 : 0.40 }
        return isFinal ? 1.0 : 0.60
    }

    /// Below this a word renders as uncertain. From `config.py:low_confidence_below`, chosen
    /// from measurement: on a clean decode words sit at 0.97 to 1.00 while genuinely
    /// ambiguous ones drop sharply, so the gap is wide and 0.55 sits well inside it.
    ///
    /// Calibrated against faster-whisper's word probabilities. A different engine produces a
    /// different distribution, so this has to be re-derived rather than carried across. See
    /// docs/MACOS-PORT.md.
    static let lowConfidenceBelow: Double = 0.55

    // MARK: - Helpers

    private static func dynamic(light: Int, dark: Int,
                                lightAlpha: Double = 1.0, darkAlpha: Double = 1.0) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension Color {
    init(hex: Int) {
        self.init(nsColor: NSColor(hex: hex, alpha: 1.0))
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: Double) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
