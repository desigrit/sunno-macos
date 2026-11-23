import SwiftUI

/// Both sidebar sections use one header and reveal their contents within the same clipped frame.
struct SidebarDisclosure<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    let reduceMotion: Bool
    var minimumHeaderHeight: CGFloat = 32
    var maximumContentHeight: CGFloat? = nil
    var onExpand: () -> Void = {}
    @ViewBuilder let content: () -> Content

    @ViewState private var contentHeight: CGFloat = 0
    private var detailFont: Font { .system(size: 11) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    isExpanded.toggle()
                }
                if isExpanded { onExpand() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(subtitle == nil ? detailFont : .system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let subtitle {
                            Text(subtitle)
                                .font(detailFont)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: minimumHeaderHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue([isExpanded ? "Expanded" : "Collapsed", subtitle].compactMap { $0 }.joined(separator: ", "))

            Group {
                if maximumContentHeight != nil {
                    ScrollView { measuredContent }
                } else {
                    measuredContent
                }
            }
            .frame(height: isExpanded ? min(contentHeight, maximumContentHeight ?? contentHeight) : 0,
                   alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .disabled(!isExpanded)
        }
    }

    private var measuredContent: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { contentHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { contentHeight = $0 }
            })
    }
}

struct SidebarLanguageSection: View {
    @ObservedObject var store: TranscriptStore
    @Binding var isExpanded: Bool
    let reduceMotion: Bool
    let onLanguage: (String) -> Void
    let onTranslate: (String) -> Void

    var body: some View {
        SidebarDisclosure(title: "Language", isExpanded: $isExpanded, reduceMotion: reduceMotion) {
            VStack(spacing: 0) {
                LanguageChoiceRow(title: "Spoken language", codes: store.spokenChoices,
                    selected: store.preparingLocale ?? store.spokenLanguage, detected: store.detectedLanguage,
                    preparing: store.preparingLocale != nil, choose: onLanguage)
                LanguageChoiceRow(title: "Translate to", codes: store.translationChoices,
                    selected: store.translationTarget, preparing: store.preparingTranslation, choose: onTranslate)
            }
            .padding(.leading, 16)
        }
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
    }
}
