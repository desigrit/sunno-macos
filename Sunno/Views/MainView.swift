import SwiftUI

/// The main window: sidebar, transcript, command bar, and the states that cover them.
struct MainView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var devices: DeviceCatalog
    @ObservedObject var chrome: WindowChrome

    let onCommand: (BackendCommand) -> Void
    let onSelectDevice: (DeviceCatalog.Device) -> Void

    @State private var renaming: SpeakerRow?

    var body: some View {
        Group {
            if store.needsModelChoice || !settings.hasCompletedSetup {
                FirstRunView(store: store, settings: settings) { model in
                    onCommand(.downloadModel(model))
                }
            } else if settings.isCompact {
                compactBody
            } else {
                fullBody
            }
        }
        .background(WindowAccessor { window in
            chrome.attach(to: window, settings: settings)
        })
        .sheet(item: $renaming) { speaker in
            SpeakerEditor(speaker: speaker, others: store.speakers) { action in
                switch action {
                case .rename(let name):
                    onCommand(.renameSpeaker(id: speaker.id, name: name))
                case .setSelf(let value):
                    onCommand(.setSelf(id: speaker.id, value: value))
                case .merge(let target):
                    onCommand(.mergeSpeakers(source: speaker.id, target: target))
                case .cancel:
                    break
                }
                renaming = nil
            }
        }
    }

    // MARK: - Full

    private var fullBody: some View {
        HSplitView {
            SidebarView(
                store: store,
                settings: settings,
                onRename: { renaming = $0 },
                onDelete: { onCommand(.deleteSpeaker(id: $0.id)) },
                onSelectModel: { onCommand(.downloadModel($0)) }
            )

            VStack(spacing: 0) {
                if let problem = store.problem {
                    ProblemBanner(problem: problem)
                    Divider()
                }
                TranscriptView(store: store, settings: settings, isCompact: false)
                    .overlay(alignment: .center) { emptyState }
                Divider()
                CommandBar(
                    store: store,
                    devices: devices,
                    onToggle: { onCommand(.toggle) },
                    onSelectDevice: onSelectDevice,
                    onRefreshDevices: { Task { await devices.refresh(fresh: true) } }
                )
            }
            .frame(minWidth: 440)
        }
    }

    // MARK: - Compact

    /// Captions and a way out. Nothing else earns its space here.
    private var compactBody: some View {
        TranscriptView(store: store, settings: settings, isCompact: true)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    // A dot when something needs attention. Compact hides the banner that
                    // would otherwise explain it, so without this a blocked microphone looks
                    // exactly like a quiet room.
                    if store.problem != nil {
                        Button { chrome.setCompact(false) } label: {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 9, height: 9)
                        }
                        .buttonStyle(.plain)
                        .help("Something needs attention. Show the full window.")
                        .accessibilityLabel("Something needs attention. Show the full window.")
                    }
                    Button { chrome.setCompact(false) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Show the full window")
                    .accessibilityLabel("Show the full window")
                }
                .padding(8)
            }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if store.lines.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.ink)
                Text(emptyTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(emptyDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false)
        }
    }

    private var emptyTitle: String {
        switch store.state {
        case "starting": return "Starting the speech engine"
        case "loading":  return "Loading the model"
        default:         return store.isRunning ? "Listening" : "Paused"
        }
    }

    private var emptyDetail: String {
        switch store.state {
        case "starting", "loading": return "This takes about half a minute the first time."
        default: return store.isRunning ? "Captions appear here as people speak." : ""
        }
    }
}

/// An actionable problem, chiefly a blocked microphone.
///
/// A banner rather than an alert. This is a persistent state carrying a remedy, not an
/// interruption to acknowledge, and an alert would have to be dismissed before the app could
/// be used to read the thing it is explaining.
private struct ProblemBanner: View {
    let problem: TranscriptStore.Problem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(problem.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let url = settingsURL {
                Link("Open Settings", destination: url)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    /// Only offered for the codes where a settings pane genuinely is the fix. Sending someone
    /// to a privacy toggle that is already switched on, because the device was simply busy,
    /// strands them: the Windows build makes the same distinction and for the same reason.
    private var settingsURL: URL? {
        guard problem.code == "mic_denied" else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
}
