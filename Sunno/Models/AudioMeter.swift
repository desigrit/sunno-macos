import Foundation

/// The input level, held apart from `TranscriptStore` deliberately.
///
/// `pipeline.py:402-415` publishes a level roughly ten times a second for as long as capture
/// runs, and it does so whether or not anyone is speaking. While these two values lived on the
/// transcript store, each of those events invalidated every view observing it: the settings
/// window redrew ten times a second, which reads as a flicker across its tab bar, and so did
/// the transcript, the sidebar and the model picker.
///
/// A separate object is the whole fix. SwiftUI invalidates per observable object, so putting
/// the only values that move at audio rate in their own type means a level event redraws the
/// meter and nothing else. Anything that changes at conversation rate belongs on the store.
@MainActor
final class AudioMeter: ObservableObject {

    /// 0 to 1. Normalised from dB rather than RMS so the meter matches what the ear hears:
    /// -60 dB reads as silence and 0 as full scale.
    @Published private(set) var level: Double = 0
    @Published private(set) var isSpeaking: Bool = false

    func update(db: Double?, speaking: Bool) {
        if let db {
            level = max(0, min(1, (db + 60) / 60))
        }
        isSpeaking = speaking
    }

    /// Capture has stopped, so the meter must not be left showing the last level it saw. A
    /// stuck bar over a released microphone is a claim the app is still listening.
    func silence() {
        level = 0
        isSpeaking = false
    }
}
