import SwiftUI

struct SidebarSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    let isExpanded: Bool
    var minimumHeight: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue([isExpanded ? "Expanded" : "Collapsed", subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

struct SidebarLanguageSection: View {
    @ObservedObject var store: TranscriptStore
    @Binding var isExpanded: Bool
    let reduceMotion: Bool
    let onLanguage: (String) -> Void
    let onTranslate: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SidebarSectionHeader(title: "Language", isExpanded: isExpanded) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { isExpanded.toggle() }
            }
            if isExpanded {
                VStack(spacing: 0) {
                    LanguageChoiceRow(title: "Spoken language", codes: store.spokenChoices,
                        selected: store.preparingLocale ?? store.spokenLanguage, detected: store.detectedLanguage,
                        preparing: store.preparingLocale != nil, choose: onLanguage)
                    LanguageChoiceRow(title: "Translate to", codes: store.translationChoices,
                        selected: store.translationTarget, preparing: store.preparingTranslation, choose: onTranslate)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
    }
}
