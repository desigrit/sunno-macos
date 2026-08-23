import SwiftUI

/// Speakers, and the model picker pinned underneath them.
struct SidebarView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    let onRename: (SpeakerRow) -> Void
    let onDelete: (SpeakerRow) -> Void
    let onSelectModel: (String) -> Void

    @State private var modelSectionOpen = false
    @State private var pendingDownload: BackendEvent.CatalogEntry?

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

    /// A disclosure holding radio rows, matching the Windows shape. The header keeps showing
    /// which model is loaded while it is closed, because that is the question it is asked most
    /// often and opening the section to answer it would be a poor trade.
    ///
    /// Built out of a `Button` rather than a `DisclosureGroup`. A disclosure on macOS wires only
    /// its chevron to the binding, and its label is inert however it is shaped, so the section
    /// could be opened only by hitting a triangle a few points across. Owning the header means
    /// the whole band is the target: the chevron, the words, and every empty point beside them.
    ///
    /// Collapsed, it is exactly as tall as the command bar on the other side of the split, so
    /// the two bottom sections read as one band rather than two that nearly line up.
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleModelSection) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
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
                // The hit area, and it is the whole band on purpose.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speech model")
            .accessibilityValue(store.activeModel ?? "not loaded")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(modelSectionOpen ? "Collapses the model list"
                                                : "Expands the model list")

            if modelSectionOpen {
                // Scrolls rather than grows without limit. Seven two-line rows are taller than
                // the sidebar on a short window, and the list is the part that should give.
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.catalog) { entry in
                            modelRow(entry)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .alert("Download \(pendingDownload?.name ?? "this model")?",
               isPresented: Binding(get: { pendingDownload != nil },
                                    set: { if !$0 { pendingDownload = nil } })) {
            Button("Download") {
                if let entry = pendingDownload { onSelectModel(entry.id) }
                pendingDownload = nil
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: {
            // Asked rather than assumed. Choosing a row is a light gesture and this one can
            // spend three gigabytes, which is not something to discover afterwards.
            Text(downloadPrompt)
        }
    }

    private func toggleModelSection() {
        if settings.reduceMotion {
            modelSectionOpen.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { modelSectionOpen.toggle() }
        }
    }

    private var downloadPrompt: String {
        guard let entry = pendingDownload else { return "" }
        return "\(sizeLabel(entry)) to download. \(entry.detail) \(entry.lagText)"
    }

    private func modelRow(_ entry: BackendEvent.CatalogEntry) -> some View {
        Button {
            // Already here, so switching is immediate. Otherwise it is a download, and one
            // worth confirming before it starts.
            if entry.available {
                onSelectModel(entry.id)
            } else {
                pendingDownload = entry
            }
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
                    Text(entry.available ? entry.lagText : "\(sizeLabel(entry)) download")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.detail)
        .accessibilityLabel("\(entry.name). \(entry.detail)")
        .accessibilityAddTraits(entry.id == store.activeModel ? [.isSelected] : [])
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

    private func sizeLabel(_ entry: BackendEvent.CatalogEntry) -> String {
        entry.approxMb >= 1000
            ? String(format: "%.1f GB", Double(entry.approxMb) / 1000)
            : "\(entry.approxMb) MB"
    }
}
