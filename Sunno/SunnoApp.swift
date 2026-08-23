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

    var body: some Scene {
        WindowGroup {
            MainView(
                store: store,
                settings: settings,
                devices: devices,
                chrome: chrome,
                backend: backend,
                onCommand: { client.send($0) },
                onSelectDevice: select
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

        client.onEvent = { event in
            store.apply(event)
            // The catalogue is only pushed unprompted when a model is missing. Ask for it
            // once the engine is up so the sidebar picker has something to show.
            if event.kind == .status, event.state == "listening" {
                client.send(.listModels)
            }
        }

        // Start on the source that was last chosen, and start on it once. Bringing the engine
        // up on the microphone and swapping to system audio afterwards costs a model load that
        // is thrown away, which is half a minute of empty window for nothing.
        guard settings.deviceName == DeviceCatalog.systemAudio.name else {
            backend.start(model: settings.selectedModel,
                          device: settings.deviceIsLoopback ? nil : settings.deviceIndex,
                          loopbackDevice: settings.deviceIsLoopback ? settings.deviceIndex : nil,
                          forceCPU: settings.forceCPU)
            client.connect(port: backend.wsPort)
            Task {
                await devices.refresh()
                reconcileSavedDevice()
            }
            return
        }

        Task {
            devices.select(DeviceCatalog.systemAudio)
            await startOnSystemAudio()
            client.connect(port: backend.wsPort)
            await devices.refresh()
        }
    }

    /// The saved device may have moved. Correct the setting and restart on the right one rather
    /// than captioning whatever now happens to sit at the old index.
    private func reconcileSavedDevice() {
        guard settings.deviceName != nil,
              let found = devices.resolve(index: settings.deviceIndex,
                                          name: settings.deviceName,
                                          isLoopback: settings.deviceIsLoopback)
        else { return }

        devices.select(found)
        guard found.index != settings.deviceIndex else { return }
        settings.deviceIndex = found.index
        restartCapture(on: found)
    }

    private func select(_ device: DeviceCatalog.Device) {
        devices.select(device)
        settings.deviceIndex = device.index
        settings.deviceName = device.name
        settings.deviceIsLoopback = device.isLoopback
        restartCapture(on: device)
    }

    /// Changing the capture source restarts the engine, which is why this is not a command on
    /// the socket: the backend takes its device from the command line and holds it open for
    /// the life of the process.
    private func restartCapture(on device: DeviceCatalog.Device) {
        guard device.isSystemAudio else {
            systemAudio.stop()
            backend.stop()
            backend.start(model: settings.selectedModel,
                          device: device.isLoopback ? nil : device.index,
                          loopbackDevice: device.isLoopback ? device.index : nil,
                          forceCPU: settings.forceCPU)
            return
        }
        Task { await startOnSystemAudio() }
    }

    /// Bring the capture up first, then hand the engine the port it serves on. The engine is
    /// stopped only once there is something for its replacement to connect to, so a refused
    /// permission leaves the working engine alone rather than killing it for nothing.
    private func startOnSystemAudio() async {
        guard await confirmScreenCapturePermission() else { return }
        do {
            let port = try await systemAudio.start()
            backend.stop()
            backend.start(model: settings.selectedModel,
                          device: nil, loopbackDevice: nil, pcmPort: port,
                          forceCPU: settings.forceCPU)
        } catch {
            systemAudio.stop()
            // Named exactly, and with the relaunch, because this permission never prompts.
            // macOS returns a denial and quietly adds the app to the list instead, so
            // somebody waiting for a dialog waits forever. Verified in the TCC log:
            // "Service kTCCServiceScreenCapture does not allow prompting; returning denied."
            store.reportProblem(
                "Sunno needs permission to capture system audio. Open Privacy & Security, "
                + "then Screen & System Audio Recording, switch Sunno on, and reopen it. "
                + "macOS will not ask on its own.",
                code: "screen_denied")
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
        lines.append("Device chosen   \(devices.selectedName == nil ? "no, using system default" : "yes")")
        lines.append("")
        lines.append("-- Preferences --")
        lines.append("Caption size    \(Int(settings.captionFontSize))")
        lines.append("Clarity shown   \(settings.showClarity)")
        lines.append("Compact mode    \(settings.isCompact)")
        lines.append("Reduce motion   \(settings.reduceMotion)")
        return lines.joined(separator: "\n")
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
