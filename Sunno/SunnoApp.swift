import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

@main
struct SunnoApp: App {

    @StateObject private var settings = AppSettings()
    @StateObject private var store = TranscriptStore()
    @StateObject private var client = CaptionClient()
    @StateObject private var devices = DeviceCatalog()
    @StateObject private var chrome = WindowChrome()
    @StateObject private var backend = BackendHost()
    @StateObject private var inputs = InputSwitch()
    @StateObject private var audioWatcher = AudioDeviceWatcher()
    @StateObject private var recording = RecordingController()
    @StateObject private var models = ModelSwitch()

    var body: some Scene {
        WindowGroup {
            MainView(
                store: store,
                settings: settings,
                devices: devices,
                chrome: chrome,
                backend: backend,
                recording: recording,
                models: models,
                onCommand: sendCommand,
                onSelectDevice: select,
                onToggleRecording: toggleRecording,
                onSelectModel: selectModel,
                onRefreshDevices: refreshDevices
            )
            .frame(minWidth: 360, minHeight: 150)
            .onAppear(perform: startUp)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { menuCommands }

        Settings {
            SettingsWindow(
                settings: settings,
                store: store,
                onCommand: sendCommand,
                diagnostics: diagnosticsReport
            )
        }
    }

    // MARK: - Menu bar
    //
    // These live here rather than in an overflow button, which is where the Windows build
    // keeps them. On macOS the menu bar is the first place someone looks, it draws its own
    // checkmarks and shortcut labels, and it is what makes the app keyboard navigable. The
    // toolbar keeps a compact-mode button as well, because it is the one command reached for
    // repeatedly and a trip to the menu bar for it would be tiresome.
    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Larger Text") { settings.stepFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { settings.stepFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)

            Divider()

            Button(settings.isCompact ? "Leave Compact Mode" : "Compact Mode") {
                chrome.setCompact(!settings.isCompact)
            }
            .keyboardShortcut("c", modifiers: [.command, .control])

            Toggle("Float on Top", isOn: Binding(
                get: { settings.alwaysOnTop },
                set: { chrome.setAlwaysOnTop($0) }
            ))
            .disabled(settings.isCompact)   // forced on while compact lasts

            Divider()

            Button("Clear Transcript") { store.clear() }
        }

        CommandGroup(replacing: .help) {
            Link("Sunno Help", destination: URL(string: "https://github.com/desigrit/sunno")!)
            Link("Privacy Policy", destination:
                URL(string: "https://github.com/desigrit/sunno/blob/master/PRIVACY.md")!)
        }
    }

    // MARK: - Wiring

    private func startUp() {
        guard backend.claimStartUp() else { return }
        devices.configure(httpPort: backend.httpPort)
        devices.select(settings.inputTarget)
        models.restart = { model in restartOnModel(model) }
        models.commit = { model in settings.selectedModel = model }
        models.notify = { message, severity in
            store.reportProblem(message, code: nil, severity: severity)
        }
        inputs.send = { client.send($0) }
        inputs.commit = { target in
            settings.rememberInput(target)
            devices.select(target)
            EngineDiagnostics.shared.redactDeviceName(target.name)
        }
        recording.onFailure = { store.reportProblem($0, code: nil, severity: .warning) }
        backend.onFailure = {
            if models.engineFailed() { return true }
            recording.reset()
            return false
        }
        client.onConnected = { inputs.reconnected() }
        client.onEvent = { event in
            guard inputs.apply(event) else { return }
            store.apply(event)
            recording.apply(event)
            applyModelSwitch(event)
            if event.kind == .input, inputs.pending == nil, let target = event.target {
                devices.select(target)
            }
            if event.kind == .status, event.model != nil,
               event.state == "listening" || event.state == "stopped" {
                client.send(.listModels)
                if devices.claimReconcile() {
                    Task {
                        await devices.refresh(fresh: true)
                        devices.select(inputs.pending ?? settings.inputTarget)
                    }
                }
            }
        }
        audioWatcher.changed = {
            client.send(.devicesChanged)
            inputs.reconnected()
            refreshDevices()
        }
        // Release capture before sleep without forgetting the user's running/paused intent.
        audioWatcher.sleeping = { inputs.suspend() }
        audioWatcher.waking = { inputs.resume() }
        audioWatcher.start()
        Task {
            let permitted = await ensurePermission(for: settings.inputTarget)
            inputs.setRunning(permitted)
            startEngine(startStopped: !permitted)
            client.connect(port: backend.wsPort)
            await devices.refresh()
        }
    }

    private func startEngine(model: String? = nil, startStopped: Bool? = nil) {
        store.beginEngineSession()
        backend.start(model: model ?? settings.selectedModel, device: nil, loopbackDevice: nil,
                      forceCPU: settings.forceCPU, recordingsPath: settings.recordingsPath,
                      resumeRecording: recording.activeFolder, input: settings.inputTarget,
                      startStopped: startStopped ?? !inputs.wanted)
    }

    private func refreshDevices() {
        Task {
            await devices.refresh(fresh: true)
            devices.select(inputs.pending ?? settings.inputTarget)
            client.send(.devicesChanged)
        }
    }

    private func sendCommand(_ command: BackendCommand) {
        switch command {
        case .start:
            resumeCapture()
        case .stop:
            _ = inputs.nextIntent()
            inputs.setRunning(false)
        case .toggle:
            if inputs.wanted {
                _ = inputs.nextIntent()
                inputs.setRunning(false)
            } else { resumeCapture() }
        default:
            client.send(command)
        }
    }

    private func resumeCapture() {
        let intent = inputs.nextIntent()
        Task {
            let permitted = await ensurePermission(for: inputs.pending ?? settings.inputTarget)
            if permitted, inputs.isCurrent(intent) {
                inputs.setRunning(true)
            }
        }
    }

    private func select(_ device: DeviceCatalog.Device) {
        let target = device.target
        let intent = inputs.nextIntent()
        // Capture is replaced in place. Recognition, speakers, transcript and recording stay.
        Task {
            let permitted = inputs.wanted ? await ensurePermission(for: target) : true
            if permitted, inputs.isCurrent(intent) {
                inputs.request(target)
                devices.select(device)
            }
        }
    }

    private func ensurePermission(for target: AudioInputTarget) async -> Bool {
        if target.kind == "loopback" {
            guard await confirmScreenCapturePermission() else { return false }
            guard CGPreflightScreenCaptureAccess() else {
                _ = CGRequestScreenCaptureAccess()
                store.reportProblem("Allow Sunno in Privacy & Security > Screen & System Audio Recording, then reopen it.",
                                    code: "screen_denied")
                return false
            }
            return true
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined, await AVCaptureDevice.requestAccess(for: .audio) { return true }
        store.reportProblem("Allow Sunno in Privacy & Security > Microphone, then try again.", code: "mic_denied")
        return false
    }

    /// The app explains before the system asks, which is the whole remedy for the wrong noun.
    ///
    /// macOS files system audio under screen recording, so the prompt says Sunno "would like to
    /// record this computer's screen" for a feature that reads no picture at all.
    /// `docs/MACOS-PORT.md` makes this a rule rather than a nicety: for an app whose users came
    /// to it because they cannot hear well, a prompt that reads as far more invasive than what
    /// is happening is a barrier at exactly the wrong moment.
    @MainActor
    private func confirmScreenCapturePermission() async -> Bool {
        guard !settings.hasSeenScreenCaptureExplanation else { return true }

        let alert = NSAlert()
        alert.messageText = "Sunno needs the screen recording permission to caption system audio"
        alert.informativeText =
            "macOS keeps the audio your Mac is playing behind that permission, so it is the one "
            + "it will ask for next. Sunno reads no picture of your screen and keeps none. The "
            + "audio is transcribed on this Mac and never sent anywhere."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        settings.hasSeenScreenCaptureExplanation = true
        return true
    }

    /// The allow-list. Named fields only, and deliberately no device names: a capture device
    /// called "Headset (R-Phonak hearing aid)" says the user wears a hearing aid, which is
    /// health information arriving through a field nobody thinks of as sensitive.
    /// Everything the model switcher needs to see, in one place.
    private func applyModelSwitch(_ event: BackendEvent) {
        switch event.kind {
        case .status:
            // The engine names its model on every status frame. "listening" is the first one
            // that proves it loaded rather than merely started loading it.
            if (event.state == "listening" || event.state == "stopped"), let model = event.model {
                models.engineReady(model: model)
            }
        case .downloadComplete:
            if let model = event.model { models.downloadFinished(model) }
        case .downloadFailed:
            if let model = event.model { models.downloadFailed(model) }
        default:
            break
        }
    }

    /// The user chose a model. Download it if needed, then restart onto it.
    ///
    /// Deliberately does not write the preference. That happens in `models` once the engine
    /// reports the model actually running, so a model that cannot be loaded is not the one
    /// waiting at the next launch.
    private func selectModel(_ model: String) {
        models.request(model, currentlyRunning: store.activeModel)
        client.send(.downloadModel(model))
    }

    /// Restart the engine onto a model. The engine reads its model once at startup, so this
    /// is the only way a switch takes effect.
    private func restartOnModel(_ model: String) {
        backend.stop()
        startEngine(model: model)
    }

    /// Start or stop recording.    ///
    /// The engine decides; this only refuses the press when there is nothing to send it to,
    /// because a command dropped into a closed socket looks exactly like a button that does
    /// nothing.
    private func toggleRecording() {
        guard client.connection == .connected else {
            store.note("Sunno is still starting up.")
            return
        }
        if recording.isRecording {
            client.send(.stopRecording)
        } else {
            client.send(.startRecording(path: settings.recordingsPath))
        }
    }

    private func diagnosticsReport() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersionString

        var lines: [String] = []
        lines.append("Sunno diagnostics")
        lines.append("Generated       \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("-- Build --")
        lines.append("App version     \(version) (\(build))")
        lines.append("macOS           \(os)")
        lines.append("Architecture    \(machineArchitecture())")
        lines.append("")
        lines.append("-- Engine --")
        lines.append("Model in use    \(store.activeModel ?? "unknown")")
        lines.append("Model setting   \(settings.selectedModel ?? "not chosen")")
        lines.append("Force CPU       \(settings.forceCPU)")
        lines.append("State           \(store.state)")
        lines.append("Backend         \(backend.status == .running ? "running" : "not running")")
        lines.append("Socket          \(client.connection == .connected ? "connected" : "not connected")")
        lines.append("Unknown events  \(client.undecodableEvents)")
        lines.append("")
        lines.append("-- Capture --")
        lines.append("Source          \(settings.deviceIsLoopback ? "system audio" : "microphone")")
        // Whether, never which. A capture device called "Headset (R-Phonak hearing aid)"
        // discloses that the user wears a hearing aid, which is health information arriving
        // through a field nobody thinks of as sensitive.
        lines.append("Device chosen   \(devices.selectedName == nil ? "no, using system default" : "yes")")
        lines.append("")
        lines.append("-- Recording --")
        lines.append("Folder chosen   \(settings.recordingsPath == nil ? "no, using the default" : "yes")")
        lines.append("State           \(recordingStateLabel)")
        lines.append("")
        lines.append("-- Preferences --")
        lines.append("Caption size    \(Int(settings.captionFontSize))")
        lines.append("Clarity shown   \(settings.showClarity)")
        lines.append("Compact mode    \(settings.isCompact)")
        lines.append("Reduce motion   \(settings.reduceMotion)")

        // The engine's own failure output, allow-listed to lines that look like a Python
        // error. Without it "the speech engine stopped" is unactionable for whoever receives
        // the report, which is the whole purpose of the file.
        if let failure = EngineDiagnostics.shared.collected() {
            lines.append("")
            lines.append("-- Last engine failure --")
            lines.append(failure)
        }
        return lines.joined(separator: "\n")
    }

    private var recordingStateLabel: String {
        switch recording.state {
        case .idle:      return "not recording"
        case .recording: return "recording"
        case .saving:    return "saving"
        case .saved:     return "saved"
        }
    }

    private func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }
}
