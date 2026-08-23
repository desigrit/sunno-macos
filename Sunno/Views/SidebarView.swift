import SwiftUI

/// Speakers, and the model picker pinned underneath them.
struct SidebarView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    let onRename: (SpeakerRow) -> Void
    let onDelete: (SpeakerRow) -> Void
    let onSelectModel: (String) -> Void

    @State private var modelSectionOpen = false

    var body: some View {
        VStack(spacing: 0) {
            speakerList
            Divider()
            modelSection
        }
        .frame(minWidth: 200, idealWidth: 232, maxWidth: 300)
    }

    private var speakerList: some View {
        List {
            Section("Speakers") {
                if store.speakers.isEmpty {
                    Text("People appear here as they speak.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(store.speakers) { speaker in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(Theme.speaker(speaker.id))
                                .frame(width: 9, height: 9)
                            Text(speaker.sidebarLabel)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Edit…") { onRename(speaker) }
                            Button("Delete") { onDelete(speaker) }
                        }
                        .accessibilityLabel(speaker.sidebarLabel)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// A disclosure rather than a popup button, matching the Windows shape. The header keeps
    /// showing which model is loaded while it is closed, because that is the question it is
    /// asked most often and opening the section to answer it would be a poor trade.
    ///
    /// Collapsed, it is exactly as tall as the command bar on the other side of the split, so
    /// the two bottom sections read as one band rather than two that nearly line up. Expanded
    /// it grows upward with the list, which is the only time the heights should differ.
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $modelSectionOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.catalog) { entry in
                        modelRow(entry)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 2)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Speech model")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(store.activeModel ?? "not loaded")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Full width and its own tap target, because a `DisclosureGroup` on macOS
                // wires only the chevron to the binding. Its label is inert however it is
                // shaped, so `contentShape` alone left a two-line header that could be opened
                // only by hitting the triangle beside it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if settings.reduceMotion {
                        modelSectionOpen.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { modelSectionOpen.toggle() }
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(modelSectionOpen ? "Collapses the model list"
                                                    : "Expands the model list")
            }
            .accessibilityLabel("Speech model")
        }
        .padding(.horizontal, 10)
        .frame(height: modelSectionOpen ? nil : CommandBar.height)
        .frame(maxHeight: modelSectionOpen ? .infinity : nil, alignment: .top)
    }

    private func modelRow(_ entry: BackendEvent.CatalogEntry) -> some View {
        Button {
            onSelectModel(entry.id)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: entry.id == store.activeModel
                      ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(entry.id == store.activeModel ? Color.accentColor : .secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(entry.name)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        if entry.id == store.activeModel {
                            badge("In use")
                        }
                    }
                    Text(entry.available ? entry.lagText : "\(entry.approxMb) MB download")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.detail)
        .accessibilityLabel("\(entry.name). \(entry.detail)")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.inkSubtle)
            )
    }
}
