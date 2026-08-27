import SwiftUI

/// The main window: sidebar, transcript, command bar, and the states that cover them.
struct MainView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var devices: DeviceCatalog
    @ObservedObject var chrome: WindowChrome
    @ObservedObject var backend: BackendHost
    @ObservedObject var recording: RecordingController
    @ObservedObject var models: ModelSwitch

    let onCommand: (BackendCommand) -> Void
    let onSelectDevice: (DeviceCatalog.Device) -> Void
    let onToggleRecording: () -> Void
    let onSelectModel: (String) -> Void
    let onRefreshDevices: () -> Void

    @State private var renaming: SpeakerRow?
    /// A named speaker waiting on confirmation before being forgotten.
    @State private var deleting: SpeakerRow?

    /// The engine's own failures, shown in the same banner as the ones it reports over the
    /// socket. `BackendHost` writes careful sentences for a missing submodule, an absent venv
    /// and an engine that stopped on its own, and until these were wired up none of them
    /// reached a window: a backend that never started left the app saying "Starting the speech
    /// engine" for as long as anyone was prepared to wait for it.
    ///
    /// A problem reported over the socket wins when there is one, because it is the more
    /// specific account of the same trouble and it carries the codes the banner offers
    /// remedies for.
    private var activeProblem: TranscriptStore.Problem? {
        if let problem = store.problem { return problem }
        if case .failed(let message) = backend.status {
            return TranscriptStore.Problem(message: message, code: nil, severity: .error)
        }
        return nil
    }

    /// The setup screen, or an engine that never started, owns the window outright.
    ///
    /// `CONTEXT.md`: entering compact is refused whenever the setup page or a dead engine owns
    /// the window, because compact would hide the thing that has to be dealt with first. Being
    /// forced out that way is not the user changing their mind, so the preference survives it
    /// and the window simply shows expanded until the obstruction clears. Without this, ⌃⌘C on
    /// the first-run picker shrinks the window over the decision it is asking for, and
    /// `isCompact` is persisted, so the next launch opens that way too.
    private var setupOwnsWindow: Bool {
        store.needsModelChoice || !settings.hasCompletedSetup
    }

    private var blocksCompact: Bool {
        if setupOwnsWindow { return true }
        if case .failed = backend.status { return true }
        return false
    }

    private var showsCompact: Bool { settings.isCompact && !blocksCompact }

    var body: some View {
        Group {
            if setupOwnsWindow {
                VStack(spacing: 0) {
                    // Above the picker too. A dead engine is exactly the case where the
                    // catalogue arrives empty, and an empty picker explains nothing.
                    if let problem = activeProblem {
                        ProblemBanner(problem: problem,
                                  detail: backend.failureDetail,
                                  onDismiss: store.dismissProblem)
                        Divider()
                    }
                    FirstRunView(store: store, settings: settings) { model in
                        onCommand(.downloadModel(model))
                    }
                }
            } else if showsCompact {
                compactBody
            } else {
                fullBody
            }
        }
        .background(WindowAccessor { window in
            chrome.attach(to: window, settings: settings)
        })
        .onAppear { chrome.setCompactBlocked(blocksCompact) }
        .onChange(of: blocksCompact) { chrome.setCompactBlocked($0) }
        // Only named speakers ask. An auto-discovered "Speaker 3" carries no work the user
        // did and reappears the moment that person speaks again, so a dialog for it is a
        // question with one sensible answer. A named one is a pinned voice profile, and
        // forgetting it cannot be undone.
        .alert("Forget \(deleting?.label ?? "")?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { speaker in
            Button("Forget", role: .destructive) {
                onCommand(.deleteSpeaker(id: speaker.id))
                deleting = nil
            }
            // Cancel is the default: the safe answer should be the one a stray return key
            // reaches.
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Sunno will stop recognising this voice, and lines already in the transcript "
                 + "will no longer show their name. This cannot be undone.")
        }
        .sheet(item: $renaming) { speaker in
            SpeakerEditor(speaker: speaker, others: store.speakers) { action in
                switch action {
                case .save(let name, let isSelf):
                    // Both, when both changed. The engine applies each and answers with one
                    // roster, so the order between them does not matter.
                    if let isSelf { onCommand(.setSelf(id: speaker.id, value: isSelf)) }
                    if let name { onCommand(.renameSpeaker(id: speaker.id, name: name)) }
                case .merge(let target):
                    onCommand(.mergeSpeakers(source: speaker.id, target: target))
                case .cancel:
                    break
                }
                renaming = nil
            }
        }
    }

    /// Named speakers are confirmed; unnamed ones go straight away.
    private func confirmDelete(_ speaker: SpeakerRow) {
        if speaker.named {
            deleting = speaker
        } else {
            onCommand(.deleteSpeaker(id: speaker.id))
        }
    }

    // MARK: - Full

    private var fullBody: some View {
        HSplitView {
            SidebarView(
                store: store,
                settings: settings,
                onRename: { renaming = $0 },
                onDelete: confirmDelete,
                // Deliberately does not write the preference. `ModelSwitch` commits it once
                // the engine reports the model actually running, so a model that downloads
                // and then fails to load is not the one waiting at the next launch.
                onSelectModel: onSelectModel,
                pendingModel: models.pending,
                onRefreshModels: { onCommand(.listModels) }
            )

            VStack(spacing: 0) {
                if let problem = activeProblem {
                    ProblemBanner(problem: problem,
                                  detail: backend.failureDetail,
                                  onDismiss: store.dismissProblem)
                    Divider()
                }
                TranscriptView(store: store, settings: settings, isCompact: false)
                    .overlay(alignment: .center) { emptyState }
                Divider()
                CommandBar(
                    store: store,
                    meter: store.meter,
                    clock: store.clock,
                    devices: devices,
                    onToggle: { onCommand(.toggle) },
                    onSelectDevice: onSelectDevice,
                    onRefreshDevices: onRefreshDevices
                )
            }
            .frame(minWidth: 440)
        }
        // The way in sits where the way out does in compact, and it is here rather than only
        // in the menu bar because it is the one command reached for repeatedly. The Windows
        // build puts it in the same relative place for the same reason.
        .toolbar {
            // Left of compact mode, and deliberately not in the transport bar at the bottom:
            // that bar is hidden in compact mode, so a recording could not be stopped from
            // there without first growing the window back.
            ToolbarItem(placement: .primaryAction) {
                RecordButton(recording: recording,
                             settings: settings,
                             onToggle: onToggleRecording)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chrome.setCompact(true)
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .help("Shrink to just the captions (⌃⌘C)")
                .accessibilityLabel("Compact mode")
            }
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
                    if activeProblem != nil {
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
    /// The engine's own reason, when there is one. Offered as "Copy details" rather than
    /// shown, because it is for whoever receives a bug report and not for the person trying
    /// to get captions back.
    let detail: String?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(problem.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let url = settingsURL {
                Link("Open Settings", destination: url)
                    .font(.system(size: 12))
            }
            if let detail {
                Button("Copy details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
                .font(.system(size: 12))
                .buttonStyle(.link)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss this message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    /// Colour is never the only signal — the symbol changes with it. This is the last app
    /// that should ask somebody to tell orange from blue to know whether captions stopped.
    private var icon: String {
        switch problem.severity {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch problem.severity {
        case .info:    return .accentColor
        case .warning: return .orange
        case .error:   return .red
        }
    }

    /// Only offered for the codes where a settings pane genuinely is the fix. Sending someone
    /// to a privacy toggle that is already switched on, because the device was simply busy,
    /// strands them: the Windows build makes the same distinction and for the same reason.
    private var settingsURL: URL? {
        switch problem.code {
        case "mic_denied":
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case "screen_denied":
            // System audio lives under screen recording on macOS, which is the whole reason
            // the app explains itself before the system is asked.
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        default:
            return nil
        }
    }
}
