import SwiftUI

/// The transcript: the thing the app is for.
struct TranscriptView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    let isCompact: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.lines) { line in
                        CaptionRow(line: line,
                                   speaker: store.speaker(line.speakerId),
                                   settings: settings,
                                   isCompact: isCompact)
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, isCompact ? 16 : 26)
                .padding(.vertical, isCompact ? 12 : 18)
            }
            .onChange(of: store.lines.count) { _ in
                // Follow the conversation. Deliberately unconditional for now: the Windows
                // build pins to the bottom the same way, and a reader who has scrolled up to
                // re-read something is a case neither app handles yet. Worth fixing on both
                // at once rather than diverging here.
                if let last = store.lines.last {
                    withAnimation(settings.reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// One utterance: an optional meta line, then the words.
private struct CaptionRow: View {
    let line: CaptionLine
    let speaker: SpeakerRow?
    @ObservedObject var settings: AppSettings
    let isCompact: Bool

    /// Compact drops the speaker, time and clarity entirely. In a window whose only content
    /// is captions, three pieces of metadata can be taller than the sentence they describe.
    private var showsMeta: Bool {
        !isCompact && speaker != nil
    }

    /// Clarity shows only on your own lines, only on a Whisper model, and only when the user
    /// has left it on. The engine reports nil on the streaming transducers, which is why this
    /// checks for a value rather than defaulting one.
    private var showsClarity: Bool {
        settings.showClarity && (speaker?.isSelf ?? false) && line.clarity != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsMeta, let speaker {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Theme.speaker(speaker.id))
                        .frame(width: 8, height: 8)
                    Text(speaker.displayLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(line.timeLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                    if showsClarity, let clarity = line.clarity {
                        Text("clarity \(clarity)%")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.clarityColor(clarity))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.clarityColor(clarity).opacity(0.13))
                            )
                    }
                }
                .accessibilityElement(children: .combine)
            }

            CaptionTextView(
                line: line,
                fontSize: settings.captionFontSize,
                opacity: Theme.lineOpacity(isFinal: line.isFinal,
                                           isSelf: speaker?.isSelf ?? false)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        // One announcement per line, carrying the speaker and the words together. Without
        // combining, VoiceOver reads the colour dot, the name, the time and the clarity badge
        // as four separate stops before reaching the sentence, which is unusable at
        // conversation speed.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let speaker, !isCompact { parts.append(speaker.displayLabel) }
        parts.append(line.text)
        return parts.joined(separator: ", ")
    }
}
