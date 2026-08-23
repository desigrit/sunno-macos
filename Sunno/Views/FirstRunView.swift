import SwiftUI

/// First run: choose a model and download it.
///
/// Window content rather than a sheet. A sheet promises something behind it to return to, and
/// on a first run there is nothing: no model means no engine, and no engine means the window
/// underneath cannot do anything yet.
///
/// Three bands rather than one scroll. Only the list grows with the size of the catalogue, so
/// only the list scrolls. The Windows build learned this when five models pushed the download
/// button off the bottom of the window: the screen asked for a decision and hid the way to
/// make it.
struct FirstRunView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    let onDownload: (String) -> Void

    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            list
            footer
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .onAppear(perform: preselect)
        .onChange(of: store.catalog.count) { _ in preselect() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                Text("Choose a speech model")
                    .font(.system(size: 22, weight: .bold))
            }
            Text("Sunno runs entirely on your Mac. Nothing is sent to the internet once this "
                 + "is downloaded, and the model is downloaded once and reused.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.catalog) { entry in
                    row(entry)
                    if entry.id != store.catalog.last?.id { Divider() }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10))
            )
        }
    }

    private func row(_ entry: BackendEvent.CatalogEntry) -> some View {
        Button {
            selected = entry.id
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: selected == entry.id
                      ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected == entry.id ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(entry.name).font(.system(size: 13, weight: .semibold))
                        if entry.available {
                            Text("Downloaded")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Theme.inkSubtle))
                        }
                    }
                    // The delay estimate is the whole point of this screen: it says what a
                    // model costs on THIS machine before three gigabytes are spent finding
                    // out. Whether it keeps up is the backend's judgement, not a fixed word
                    // in a description.
                    Text("\(entry.detail) \(entry.lagText)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(entry.responsive ? .secondary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                Text(sizeLabel(entry))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(selected == entry.id ? Color.accentColor.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.name). \(entry.detail) \(entry.lagText). \(sizeLabel(entry))")
        .accessibilityAddTraits(selected == entry.id ? [.isSelected] : [])
    }

    private func sizeLabel(_ entry: BackendEvent.CatalogEntry) -> String {
        entry.approxMb >= 1000
            ? String(format: "%.1f GB", Double(entry.approxMb) / 1000)
            : "\(entry.approxMb) MB"
    }

    /// A download that is running, as opposed to one that has failed and is now just a
    /// message on screen. Only the first should disable the button: after a failure the
    /// whole point is to be able to try again.
    private var isDownloading: Bool {
        guard let download = store.download else { return false }
        return download.failed == nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let download = store.download {
                if let failure = download.failed {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else {
                    ProgressView(value: download.percent, total: 100)
                    Text("Downloading \(download.model), \(Int(download.percent))%")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Download and Continue") {
                    if let selected {
                        settings.selectedModel = selected
                        settings.hasCompletedSetup = true
                        onDownload(selected)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil || isDownloading)

                Text("You can change the model later.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 18)
    }

    /// Preselect what the machine can actually keep up with, never a model the app is
    /// forbidden from choosing on someone's behalf.
    ///
    /// `autoSelect` is false for models whose publisher declares no licence. A user who reads
    /// the notices and picks one anyway has chosen it; the app arriving at one by itself
    /// would make that disclosure false.
    private func preselect() {
        guard selected == nil, !store.catalog.isEmpty else { return }
        selected = store.catalog.first { $0.responsive && $0.autoSelect }?.id
            ?? store.catalog.first { $0.autoSelect }?.id
            ?? store.catalog.first?.id
    }
}
