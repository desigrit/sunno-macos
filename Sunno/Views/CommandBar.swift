import SwiftUI

/// The bottom bar: what is being heard, the transport, and what the engine is doing.
///
/// A bottom bar is slightly unusual on macOS, where this would normally be a toolbar. It
/// stays because of what it contains: the level meter belongs beside the device that produces
/// it, and moving the pair to the top would separate the meter from the picker it describes.
/// The Windows build makes the same argument in the same words.
struct CommandBar: View {
    /// The height of the bottom band, shared with the sidebar's model section so the two
    /// bottom sections line up across the split. They are separate views either side of an
    /// `HSplitView`, so nothing enforces this but the constant.
    static let height: CGFloat = 64

    @ObservedObject var store: TranscriptStore
    @ObservedObject var meter: AudioMeter
    @ObservedObject var clock: SessionClock
    @ObservedObject var devices: DeviceCatalog
    let onToggle: () -> Void
    let onSelectDevice: (DeviceCatalog.Device) -> Void
    let onRefreshDevices: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                levelMeter
                Image(systemName: "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                devicePicker
                Button(action: onRefreshDevices) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Look for devices plugged in since Sunno started")
                .accessibilityLabel("Refresh device list")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transport

            Text(statusLine)
                .font(.system(size: 11.5))
                .foregroundStyle(isStalled ? Color.orange : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(statusHint)
                .accessibilityLabel(statusLine)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
    }

    /// A vertical bar rather than a horizontal one. It reads as "how loud" at a glance and
    /// costs almost no width, which matters beside a picker that already wants 190 points.
    private var levelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: max(0, geometry.size.height * meter.level))
            }
        }
        .frame(width: 4, height: 24)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(meter.level * 100)) percent")
    }

    private var devicePicker: some View {
        Menu {
            if devices.inputs.isEmpty {
                Text("No microphones found")
            }
            ForEach(devices.inputs) { device in
                Button(device.name) { onSelectDevice(device) }
            }
            if !devices.outputs.isEmpty {
                Divider()
                Section("System audio") {
                    ForEach(devices.outputs) { device in
                        Button(device.name) { onSelectDevice(device) }
                    }
                }
            }
        } label: {
            Text(devices.selectedName ?? "Default microphone")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 150, maxWidth: 230)
        .accessibilityLabel("Input device")
    }

    /// Pause bars rather than a stop square, carried over from the Windows build along with
    /// its reasoning. The backend has always treated this as a pause: the model and the ASR
    /// worker stay resident across cycles, so resuming costs a fraction of a second rather
    /// than the half minute a cold start takes. A stop square promises otherwise, which
    /// discourages ducking out of a conversation for an aside. The microphone genuinely is
    /// released either way, and the status line keeps saying so.
    private var transport: some View {
        Button(action: onToggle) {
            Image(systemName: store.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Color.accentColor))
        .foregroundStyle(.white)
        .keyboardShortcut(.space, modifiers: [])
        .help(store.isRunning ? "Pause transcribing (Space)" : "Resume transcribing (Space)")
        .accessibilityLabel(store.isRunning ? "Pause transcribing" : "Resume transcribing")
    }

    /// The status corner is a recording indicator rather than a status bar, so while capture
    /// is running it shows the conversation clock and any other message takes the line back.
    /// Ported from `MainWindow.xaml.cs:718-802` with its reasoning.
    private var isStalled: Bool {
        store.state == "listening" && store.isRunning && clock.isStalled
    }

    private var statusLine: String {
        if let download = store.download {
            return "Downloading \(download.model), \(Int(download.percent))%"
        }
        switch store.state {
        case "starting":  return "Starting the speech engine"
        case "loading":   return "Loading \(store.activeModel ?? "model")"
        case "listening":
            guard store.isRunning else { return "Paused, microphone released" }
            return clock.isStalled ? "No audio" : clock.display
        case "stopped":   return "Paused, microphone released"
        default:          return store.state
        }
    }

    /// The accumulated time moves into the tooltip rather than vanishing whenever a message
    /// owns the line. While paused that message is a privacy assertion, which outranks a
    /// number the reader can still hover for.
    private var statusHint: String {
        if isStalled {
            return "The device is open but no sound is reaching it. Try another input."
        }
        if store.state == "listening", store.isRunning {
            return "How long this conversation has been recording"
        }
        return clock.hasRun
            ? "\(clock.display) recorded, microphone released"
            : "Microphone released"
    }
}
