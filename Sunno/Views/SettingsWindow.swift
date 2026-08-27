import SwiftUI

/// Settings, as a separate window opened with Command comma.
///
/// This is the one place the macOS build deliberately departs from the Windows shape. There,
/// Settings is a full-window page with a back arrow, matching the Windows inbox apps. Here it
/// is a `Settings` scene with a toolbar of tabs, because that is where a Mac user looks and
/// because Command comma has to open something. Keeping the page would have been the most
/// obviously non-native thing left in the app. Recorded in docs/MACOS-PORT.md as a decision
/// rather than an accident.
struct SettingsWindow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: TranscriptStore
    let onCommand: (BackendCommand) -> Void
    let diagnostics: () -> String

    var body: some View {
        TabView {
            CaptionsPane(settings: settings)
                .tabItem { Label("Captions", systemImage: "captions.bubble") }
            EnginePane(settings: settings, store: store)
                .tabItem { Label("Engine", systemImage: "gearshape") }
            RecordingsPane(settings: settings)
                .tabItem { Label("Recordings", systemImage: "record.circle") }
            SpeakersPane(store: store, onCommand: onCommand)
                .tabItem { Label("Speakers", systemImage: "person.2") }
            DiagnosticsPane(diagnostics: diagnostics)
                .tabItem { Label("Diagnostics", systemImage: "arrow.down.doc") }
        }
        .frame(width: 620, height: 430)
    }
}

private struct CaptionsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Clarity score on your own lines", isOn: $settings.showClarity)
            Text("How clearly you were heard, shown on speech you have marked as your own. "
                 + "Whisper models only.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Caption text size", selection: $settings.captionFontSize) {
                ForEach(AppSettings.fontSizes, id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }
            Text("Also adjustable with Command plus and Command minus at any time.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct EnginePane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: TranscriptStore

    var body: some View {
        Form {
            Toggle("Use the processor instead of the GPU and Neural Engine",
                   isOn: $settings.forceCPU)
            Text("Slower, but a way back in if the engine stops starting. Reloads the model, "
                 + "which takes about half a minute.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Model in use", value: store.activeModel ?? "none")
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct RecordingsPane: View {
    @ObservedObject var settings: AppSettings

    /// Resolved for display only. The setting itself stays nil until somebody chooses a
    /// folder, so the default is not baked into a preference file and the folder is still
    /// only created when a recording is actually saved.
    private var effectivePath: String {
        if let chosen = settings.recordingsPath, !chosen.isEmpty { return chosen }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sunno/Recordings").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recordings are saved here")
                .font(.system(size: 12, weight: .medium))
            Text(effectivePath)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Change…") { choose() }
                Button("Open Folder") { reveal() }
                if settings.recordingsPath != nil {
                    Button("Use the Default") { settings.recordingsPath = nil }
                }
            }

            Divider()

            Text("Nothing is written until you press record, and the folder is not created "
                 + "until the first recording is saved. Each one is a folder holding the "
                 + "audio and the transcript, as text and as JSON.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Said plainly because the app's whole claim is that conversations stay on the
            // machine, and a recording is the one thing that outlives the session.
            Text("Not in Documents by default: macOS syncs Desktop and Documents to iCloud "
                 + "for a great many people who never chose it, and a recording of a "
                 + "conversation should not be uploaded because of a setting nobody read.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(18)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordingsPath = url.path
        }
    }

    private func reveal() {
        // Created on demand rather than at startup: an install that never records should
        // leave nothing behind, and this is the first moment the folder has to exist.
        let url = URL(fileURLWithPath: effectivePath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

private struct SpeakersPane: View {    @ObservedObject var store: TranscriptStore
    let onCommand: (BackendCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.speakers.isEmpty {
                Text("Nobody has been recognised yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                List(store.speakers) { speaker in
                    HStack(spacing: 10) {
                        Circle().fill(Theme.speaker(speaker.id)).frame(width: 10, height: 10)
                        Text(speaker.sidebarLabel)
                        Spacer()
                        Button("Delete") { onCommand(.deleteSpeaker(id: speaker.id)) }
                            .accessibilityLabel("Delete \(speaker.displayLabel)")
                    }
                }
            }
            Divider()
            Button("Forget everyone who has not been named") {
                onCommand(.resetSpeakers)
            }
            Text("Named people are kept. Everyone else is discovered again as they speak.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }
}

/// The report a user attaches to a bug report.
///
/// Built as an allow-list rather than a filter, and that distinction is the whole design.
/// Sunno's claim is that conversations never leave the machine, so the one feature whose
/// purpose is to send a file to a stranger is the one place that claim is easiest to break.
/// A filter has to anticipate every category of secret; an allow-list only emits what someone
/// deliberately put on it. See `app/Services/Diagnostics.cs`, whose reasoning this inherits.
private struct DiagnosticsPane: View {
    let diagnostics: () -> String
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("If something isn't working, send these logs to the developer. Everything "
                 + "that would be shared is below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Selectable, so Command C still works if the button ever fails.
            TextEditor(text: .constant(text))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 200)
                .accessibilityLabel("Diagnostics report")

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Save to a File…") { save() }
            }
        }
        .padding(18)
        .onAppear { text = diagnostics() }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sunno-diagnostics.txt"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
