import SwiftUI
import AppKit

@main
struct SunnoApp: App {

    @StateObject private var settings = AppSettings()
    @StateObject private var store = TranscriptStore()
    @StateObject private var client = CaptionClient()
    @StateObject private var devices = DeviceCatalog()
    @StateObject private var chrome = WindowChrome()
    @StateObject private var backend = BackendHost()
    @StateObject private var systemAudio = SystemAudioCapture()
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
                onCommand: { client.send($0) },
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
                onCommand: { client.send($0) },
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
        // Once per launch, whatever SwiftUI does with the view. `onAppear` fires again whenever
        // the hierarchy is rebuilt, and this method replaces the engine: running it twice tore
        // down a model that was still loading and started another, so the window never reached
        // "listening" and no caption ever arrived. It looked like captions were broken.
        guard backend.claimStartUp() else { return }

        devices.configure(httpPort: backend.httpPort)

        // The switcher owns the decision; the app owns the engine and the preference file.
        models.restart = { model in restartOnModel(model) }
        models.commit = { model in settings.selectedModel = model }
        models.notify = { message, severity in
            store.reportProblem(message, code: nil, severity: severity)
        }
        // The one string the app knows to be sensitive, so an engine error that names the
        // capture device cannot put it in a report.
        EngineDiagnostics.shared.redactDeviceName(settings.deviceName)
        recording.onFailure = { message in
            store.reportProblem(message, code: nil, severity: .warning)
        }
        // An engine that dies while a switch is in flight is the switch's failure to handle
        // first. Only if it declines does the banner report it as a plain crash.
        backend.onFailure = {
            if models.engineFailed() { return true }
            recording.reset()
            return false
        }

        client.onEvent = { event in
            store.apply(event)
            recording.apply(event)
            applyModelSwitch(event)
            // The catalogue is only pushed unprompted when a model is missing. Ask for it
            // once the engine is up so the sidebar picker has something to show.
            if event.kind == .status, event.state == "listening" {
                client.send(.listModels)
                // The engine is up, so its device list is answerable now. The refresh at
                // launch can land before its HTTP server is listening, and reconciling
                // against an empty list reported a perfectly good microphone as missing.
                if devices.claimReconcile() {
                    Task {
                        await devices.refresh()
                        reconcileSavedDevice()
                    }
                }
            }
        }

        // Start on the source that was last chosen, and start on it once. Bringing the engine
        // up on the microphone and swapping to system audio afterwards costs a model load that
        // is thrown away, which is half a minute of empty window for nothing.
        guard settings.deviceName == DeviceCatalog.systemAudio.name else {
            store.beginEngineSession()
            backend.start(model: settings.selectedModel,
                          device: settings.deviceIsLoopback ? nil : settings.deviceIndex,
                          loopbackDevice: settings.deviceIsLoopback ? settings.deviceIndex : nil,
                          forceCPU: settings.forceCPU,
                          recordingsPath: settings.recordingsPath,
                          resumeRecording: recording.activeFolder)
            client.connect(port: backend.wsPort)
            Task { await devices.refresh() }
            return
        }

        Task {
            devices.select(DeviceCatalog.systemAudio)
            if await startOnSystemAudio() == false {
                // Fall back rather than sit there with no engine at all. A permission that was
                // never granted should cost the feature that needs it, not the whole app: an
                // accessibility tool that captions nothing because one capture path was refused
                // has failed at the only thing it is for. The banner still says what happened.
                devices.select(DeviceCatalog.systemAudio)
                startOnMicrophone()
            }
            client.connect(port: backend.wsPort)
            await devices.refresh()
        }
    }

    /// The default input, with whatever device the settings remember.
    ///
    /// `model` overrides the saved preference, which is how a switch reaches the engine
    /// before the preference has been committed to it.
    private func startOnMicrophone(model: String? = nil) {
        store.beginEngineSession()
        backend.start(model: model ?? settings.selectedModel,
                      device: settings.deviceIsLoopback ? nil : settings.deviceIndex,
                      loopbackDevice: settings.deviceIsLoopback ? settings.deviceIndex : nil,
                      forceCPU: settings.forceCPU,
                      recordingsPath: settings.recordingsPath,
                      resumeRecording: recording.activeFolder)
    }

    /// The saved device may have moved. Correct the setting and restart on the right one rather
    /// than captioning whatever now happens to sit at the old index.
    ///
    /// When it has gone altogether, say so. A microphone that disappears produces silence,
    /// and silence is indistinguishable from a quiet room — which is the one failure this app
    /// cannot afford to leave unexplained.
    private func reconcileSavedDevice() {
        guard let wanted = settings.deviceName else { return }

        // An empty catalogue means the engine has not answered yet, not that every microphone
        // has gone. At startup the refresh can land before the engine's HTTP server is up,
        // and announcing from that produced "MacBook Pro Microphone is not available" over a
        // session that was captioning from it perfectly well. A banner that cries wolf is
        // worse than no banner: this one has to be believed the day it says the microphone
        // really has gone.
        guard !devices.inputs.isEmpty || !devices.outputs.isEmpty else { return }

        guard let found = devices.resolve(index: settings.deviceIndex,
                                          name: wanted,
                                          isLoopback: settings.deviceIsLoopback)
        else {
            announceMissingDevice(wanted)
            return
        }

        devices.select(found)
        guard found.index != settings.deviceIndex else { return }
        settings.deviceIndex = found.index
        restartCapture(on: found)
    }

    /// Re-enumerate, then check the remembered device is still there.
    private func refreshDevices() {
        Task {
            await devices.refresh(fresh: true)
            reconcileSavedDevice()
        }
    }

    /// Three sentences, because the right thing to do next differs in each case.
    ///
    /// After a manual refresh the engine is already holding an open stream on a real device,
    /// so nothing is broken and the app must not restart capture to chase an index — that
    /// would stop captions mid-conversation to fix something that is not wrong. It only
    /// offers the choice.
    private func announceMissingDevice(_ wanted: String) {
        if devices.lastRefreshWasStale {
            store.note("\(wanted) is not available. Choose a device below if you want to "
                       + "switch.")
            return
        }
        if let alternative = devices.selected ?? devices.inputs.first(where: { $0.isDefault })
                             ?? devices.inputs.first {
            store.note("\(wanted) is not available, so Sunno is using \(alternative.name) "
                       + "instead.")
        } else {
            store.note("\(wanted) is not available. Choose a microphone below to start "
                       + "captioning.")
        }
    }

    private func select(_ device: DeviceCatalog.Device) {
        devices.select(device)
        settings.deviceIndex = device.index
        settings.deviceName = device.name
        settings.deviceIsLoopback = device.isLoopback
        EngineDiagnostics.shared.redactDeviceName(device.name)
        restartCapture(on: device)
    }

    /// Changing the capture source restarts the engine, which is why this is not a command on
    /// the socket: the backend takes its device from the command line and holds it open for
    /// the life of the process.
    private func restartCapture(on device: DeviceCatalog.Device) {
        guard device.isSystemAudio else {
            systemAudio.stop()
            backend.stop()
            store.beginEngineSession()
            backend.start(model: settings.selectedModel,
                          device: device.isLoopback ? nil : device.index,
                          loopbackDevice: device.isLoopback ? device.index : nil,
                          forceCPU: settings.forceCPU,
                          recordingsPath: settings.recordingsPath,
                          resumeRecording: recording.activeFolder)
            return
        }
        Task {
            if await startOnSystemAudio() == false, backend.status != .running {
                // Whenever the attempt left nothing running, which includes an engine that
                // failed to spawn as well as one that was never started. A refusal that
                // happened before the old engine was stopped has already left a working one
                // in place, and that case is the reason this is a check rather than an else.
                startOnMicrophone()
            }
        }
    }

    /// Bring the capture up first, then hand the engine the port it serves on. The engine is
    /// stopped only once there is something for its replacement to connect to, so a refused
    /// permission leaves the working engine alone rather than killing it for nothing.
    @discardableResult
    private func startOnSystemAudio(model: String? = nil) async -> Bool {
        guard await confirmScreenCapturePermission() else { return false }
        do {
            let port = try await systemAudio.start()
            backend.stop()
            store.beginEngineSession()
        backend.start(model: model ?? settings.selectedModel,
                          device: nil, loopbackDevice: nil, pcmPort: port,
                          forceCPU: settings.forceCPU,
                          recordingsPath: settings.recordingsPath,
                          resumeRecording: recording.activeFolder)

            // `start` reports failure by setting a status rather than by throwing, so success
            // has to be read back. Returning true regardless left the capture running, the
            // recording indicator lit and PCM going to a socket nobody was reading, while the
            // caller believed system audio was working and never fell back.
            guard backend.status == .running else {
                systemAudio.stop()
                return false
            }
            return true
        } catch SystemAudioCapture.CaptureError.notPermitted {
            systemAudio.stop()
            // Named exactly, and with the relaunch, because this permission never prompts.
            // macOS returns a denial and quietly adds the app to the list instead, so somebody
            // waiting for a dialog waits forever. Verified in the TCC log: "Service
            // kTCCServiceScreenCapture does not allow prompting; returning denied."
            store.reportProblem(
                "Sunno needs permission to capture system audio. Open Privacy & Security, "
                + "then Screen & System Audio Recording, switch Sunno on, and reopen it. "
                + "macOS will not ask on its own. Listening to the microphone meanwhile.",
                code: "screen_denied")
            return false
        } catch {
            systemAudio.stop()
            // Anything else, said plainly. Permission has already been ruled out above, so
            // repeating the Settings advice here would send somebody to a switch that is
            // already on.
            store.reportProblem(
                "System audio could not be captured. \(error.localizedDescription) "
                + "Listening to the microphone meanwhile.",
                code: nil)
            return false
        }
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
            if event.state == "listening", let model = event.model {
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
        let device = devices.selected
        systemAudio.stop()
        backend.stop()
        if let device, device.isSystemAudio {
            Task {
                if await startOnSystemAudio(model: model) == false {
                    startOnMicrophone(model: model)
                }
            }
            return
        }
        startOnMicrophone(model: model)
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
