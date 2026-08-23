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

    var body: some Scene {
        WindowGroup {
            MainView(
                store: store,
                settings: settings,
                devices: devices,
                chrome: chrome,
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
        devices.configure(httpPort: backend.httpPort)

        client.onEvent = { event in
            store.apply(event)
            // The catalogue is only pushed unprompted when a model is missing. Ask for it
            // once the engine is up so the sidebar picker has something to show.
            if event.kind == .status, event.state == "listening" {
                client.send(.listModels)
            }
        }

        backend.start(model: settings.selectedModel,
                      device: nil,
                      loopbackDevice: nil,
                      forceCPU: settings.forceCPU)
        client.connect(port: backend.wsPort)

        Task { await devices.refresh() }
    }

    private func select(_ device: DeviceCatalog.Device) {
        devices.select(device)
        // Changing the capture source restarts the engine, which is why this is not a
        // command on the socket: the backend takes its device from the command line and
        // holds it open for the life of the process.
        backend.stop()
        backend.start(model: settings.selectedModel,
                      device: device.isLoopback ? nil : device.index,
                      loopbackDevice: device.isLoopback ? device.index : nil,
                      forceCPU: settings.forceCPU)
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
