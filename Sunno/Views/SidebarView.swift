import SwiftUI

/// Speakers, and the model picker pinned underneath them.
struct SidebarView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    let onRename: (SpeakerRow) -> Void
    let onDelete: (SpeakerRow) -> Void
    let onSelectModel: (String) -> Void

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

    /// A pop-up button, which is what macOS uses for one-of-many when the list is longer than
    /// a few entries. The Human Interface Guidelines put the boundary at about five and the
    /// catalogue holds seven, so radio rows were the wrong control before the sidebar's width
    /// is even considered.
    ///
    /// What it replaced was a `DisclosureGroup` holding those rows. Two things were wrong with
    /// it. A disclosure on macOS only toggles from its chevron, so the header could be opened
    /// only by hitting a triangle a few points across. And expanding it pushed seven two-line
    /// rows into a 232 point column, which is where a menu belongs instead: a pop-up button
    /// shows the current answer at rest and the full list, at full width, on demand.
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Speech model")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Menu {
                // Split, because the difference between them is a download. Ordering follows
                // the catalogue, which the engine already sorts best-accuracy-first.
                let downloaded = store.catalog.filter(\.available)
                let available = store.catalog.filter { !$0.available }

                if !downloaded.isEmpty {
                    Section("On this Mac") {
                        ForEach(downloaded) { entry in modelItem(entry) }
                    }
                }
                if !available.isEmpty {
                    Section("Available to download") {
                        ForEach(available) { entry in modelItem(entry) }
                    }
                }
            } label: {
                Text(activeLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Speech model")
            .accessibilityValue(activeLabel)
        }
        .padding(.horizontal, 10)
        .frame(height: CommandBar.height)
        .alert("Download \(pendingDownload?.name ?? "this model")?",
               isPresented: Binding(get: { pendingDownload != nil },
                                    set: { if !$0 { pendingDownload = nil } })) {
            Button("Download") {
                if let entry = pendingDownload { onSelectModel(entry.id) }
                pendingDownload = nil
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: {
            // Asked rather than assumed. Choosing from a menu is a light gesture and this one
            // can spend three gigabytes, which is not something to discover afterwards.
            Text(downloadPrompt)
        }
    }

    private var downloadPrompt: String {
        guard let entry = pendingDownload else { return "" }
        return "\(sizeLabel(entry)) to download. \(entry.detail) \(entry.lagText)"
    }

    @ViewBuilder
    private func modelItem(_ entry: BackendEvent.CatalogEntry) -> some View {
        Button {
            // Already here, so switching is immediate. Otherwise it is a download, and the
            // engine reloads either way, which the status line reports.
            if entry.available {
                onSelectModel(entry.id)
            } else {
                pendingDownload = entry
            }
        } label: {
            Text(menuLabel(entry))
        }
        .disabled(entry.id == store.activeModel)
    }

    /// The current model, plus what it costs, because that is the question this control is
    /// asked most often and reading it should not require opening anything.
    private var activeLabel: String {
        guard let active = store.activeModel else { return "not loaded" }
        guard let entry = store.catalog.first(where: { $0.id == active }) else { return active }
        return "\(entry.name) · \(entry.lagText)"
    }

    private func menuLabel(_ entry: BackendEvent.CatalogEntry) -> String {
        entry.available
            ? "\(entry.name) · \(entry.lagText)"
            : "\(entry.name) · \(sizeLabel(entry))"
    }

    private func sizeLabel(_ entry: BackendEvent.CatalogEntry) -> String {
        entry.approxMb >= 1000
            ? String(format: "%.1f GB", Double(entry.approxMb) / 1000)
            : "\(entry.approxMb) MB"
    }
}
