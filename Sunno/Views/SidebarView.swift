import SwiftUI

/// Speakers, and the model picker pinned underneath them.
struct SidebarView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    let onRename: (SpeakerRow) -> Void
    let onDelete: (SpeakerRow) -> Void
    let onSelectModel: (String) -> Void
    let onRefreshModels: () -> Void

    @State private var modelSectionOpen = false
    @State private var pendingDownload: BackendEvent.CatalogEntry?
    @State private var listHeight: CGFloat = 0

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

    /// The model list, revealed by animating a clipped height rather than by inserting rows.
    ///
    /// Inserting them made the contents appear all at once while the header was still moving,
    /// which reads as two separate events. The Windows build solved this by animating the
    /// height of a container that clips, and this is the same thing in SwiftUI: the rows are
    /// always laid out at their natural size, and the frame around them opens from zero.
    ///
    /// No scrolling. The section takes the height it needs and the speaker list above gives up
    /// the space, which is what a panel this short should do with seven rows.
    private var modelSection: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .animation(settings.reduceMotion ? nil : .easeOut(duration: 0.22), value: modelSectionOpen)
        .alert("Download \(pendingDownload?.name ?? "this model")?",
               isPresented: Binding(get: { pendingDownload != nil },
                                    set: { if !$0 { pendingDownload = nil } })) {
            Button("Download") {
                if let entry = pendingDownload { onSelectModel(entry.id) }
                pendingDownload = nil
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: {
            // Asked rather than assumed. Choosing a row is a light gesture and one of these
            // rows is three gigabytes.
            Text(downloadPrompt)
        }
    }

    /// A `Button`, not a `DisclosureGroup` label. A disclosure on macOS wires only its chevron
    /// to the binding and its label is inert however it is shaped, so the section could be
    /// opened only by hitting a triangle a few points across. Owning the header means the whole
    /// band responds: the chevron, the words, and every empty point beside them.
    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(modelSectionOpen ? 90 : 0))

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

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: CommandBar.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speech model")
        .accessibilityValue(store.activeModel ?? "not loaded")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(modelSectionOpen ? "Collapses the model list" : "Expands the model list")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.catalog) { entry in
                modelRow(entry)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measured at its natural height, before the frame below collapses it, so the open
        // state has a real number to animate to rather than a guess.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        .frame(height: modelSectionOpen ? listHeight : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(modelSectionOpen)
        .accessibilityHidden(!modelSectionOpen)
    }

    private func toggle() {
        modelSectionOpen.toggle()
        // Re-ask for the catalogue on open. The delay figures are learned from real decodes,
        // and the first fetch happens on connect before a single utterance has been timed, so
        // without this somebody would keep reading the shipped estimate all session.
        if modelSectionOpen { onRefreshModels() }
    }

    private var downloadPrompt: String {
        guard let entry = pendingDownload else { return "" }
        return "\(sizeLabel(entry)) to download. \(entry.detail)"
    }

    /// Two columns: name and description on the left, and, only when the model is not on disk,
    /// its download size and a download glyph on the right. Keeping the size out of the
    /// description line leaves the description readable and makes a missing model recognisable
    /// without reading anything. Carried over from `ModelRow.cs`, which says the same.
    private func modelRow(_ entry: BackendEvent.CatalogEntry) -> some View {
        Button {
            if entry.available {
                onSelectModel(entry.id)
            } else {
                pendingDownload = entry
            }
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: entry.id == store.activeModel
                      ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(entry.id == store.activeModel ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if entry.id == store.activeModel {
                            badge("In use")
                        }
                    }
                    Text(secondaryText(entry))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                if !entry.available {
                    HStack(spacing: 4) {
                        Text(sizeLabel(entry))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The pane is 232 points and both lines trim, so the full text has to be reachable.
        .help(tooltip(entry))
        .accessibilityLabel(tooltip(entry).replacingOccurrences(of: "\n", with: ", "))
        .accessibilityAddTraits(entry.id == store.activeModel ? [.isSelected] : [])
    }

    /// The description, prefixed with the expected delay. A parenthetical rather than its own
    /// column, because a column of delays invites reading them as a ranking, which made the
    /// most accurate model look like the worst choice.
    private func secondaryText(_ entry: BackendEvent.CatalogEntry) -> String {
        guard entry.lagMs > 0 else { return entry.detail }
        let seconds = Double(entry.lagMs) / 1000
        let delay = entry.lagMs < 1000
            ? String(format: "(~%.1fs delay)", seconds)
            : String(format: "(~%.0fs delay)", seconds)
        return "\(delay) \(entry.detail)"
    }

    /// Full text for hover, in the shape `ModelRow.Tooltip` uses.
    private func tooltip(_ entry: BackendEvent.CatalogEntry) -> String {
        var text = entry.detail.isEmpty ? entry.name : "\(entry.name)\n\(entry.detail)"
        if entry.lagMs > 0 {
            text += String(format: "\nCaptions appear about %.1fs after each sentence",
                           Double(entry.lagMs) / 1000)
            if !entry.responsive {
                text += ", which is too slow to follow a live conversation"
            }
        }
        return entry.available ? text : "\(text)\n\(sizeLabel(entry)) download"
    }

    /// Binary megabytes and a trimmed decimal, matching `ModelRow.FormatSize` exactly: 3090 MB
    /// reads as "3 GB" here and on Windows, not "3.1 GB".
    private func sizeLabel(_ entry: BackendEvent.CatalogEntry) -> String {
        guard entry.approxMb >= 1024 else { return "\(entry.approxMb) MB" }
        let gb = Double(entry.approxMb) / 1024
        let trimmed = (gb * 10).rounded() / 10
        return trimmed == trimmed.rounded()
            ? String(format: "%.0f GB", trimmed)
            : String(format: "%.1f GB", trimmed)
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
            .fixedSize()
    }
}

/// The list's natural height, so the reveal has a number to animate to.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
