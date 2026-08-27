import SwiftUI

/// The record control: a pill that grows out of a ring and back.
///
/// Idle it is a 30pt circle carrying a record ring. Recording, it grows leftward into the
/// app's own green with a dot and a running timer. Saving, it shrinks back to a spinner, and
/// lands on a tick before returning to rest.
///
/// **The dot does not blink.** A pulsing light in the corner is movement in the reader's
/// peripheral vision for the whole meeting, which is the last thing an app should add when
/// the entire point of it is to hold someone's attention on a line of text.
///
/// It lives in the toolbar beside compact mode rather than in the transport bar at the
/// bottom. The transport bar is hidden in compact mode and already carries the "No audio"
/// warning; a control that disappears when the window shrinks is a control that stops a
/// recording by accident.
struct RecordButton: View {
    @ObservedObject var recording: RecordingController
    @ObservedObject var settings: AppSettings
    let onToggle: () -> Void

    /// Pinned, so the pill is one width for any ordinary meeting rather than re-laying out
    /// every time a digit changes and nudging the buttons beside it. It grows once past an
    /// hour and then holds again.
    private var timerWidth: CGFloat {
        recording.elapsed >= 3600 ? 52 : 34
    }

    private var isLive: Bool {
        if case .recording = recording.state { return true }
        return false
    }

    private var pillWidth: CGFloat {
        isLive ? 13 * 2 + timerWidth + 7 + 8 : 30
    }

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                Capsule()
                    .fill(Theme.ink)
                    .opacity(isLive ? 1 : 0)
                content
            }
            .frame(width: pillWidth, height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        // Reduce Motion is honoured because this is the one animated thing that runs for the
        // whole length of a meeting.
        .animation(settings.reduceMotion ? nil : .easeOut(duration: 0.26), value: pillWidth)
        .animation(settings.reduceMotion ? nil : .easeOut(duration: 0.2), value: isLive)
    }

    @ViewBuilder
    private var content: some View {
        switch recording.state {
        case .idle:
            Image(systemName: "record.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

        case .recording:
            HStack(spacing: 7) {
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                Text(RecordingController.clock(recording.elapsed))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: timerWidth, alignment: .leading)
            }

        case .saving:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)

        case .saved:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                // Lands rather than fades in. This is the only confirmation that a meeting
                // became a file, so it should feel like a result.
                .transition(settings.reduceMotion
                            ? .opacity
                            : .scale(scale: 0.4).combined(with: .opacity))
        }
    }

    private var helpText: String {
        switch recording.state {
        case .idle:      return "Record this conversation to a file"
        case .recording: return "Stop and save this recording"
        case .saving:    return "Saving…"
        case .saved(let name, let duration):
            return "Saved \(name) (\(RecordingController.clock(duration)))"
        }
    }

    private var accessibilityText: String {
        switch recording.state {
        case .idle:      return "Start recording"
        case .recording: return "Stop recording, \(RecordingController.clock(recording.elapsed))"
        case .saving:    return "Saving recording"
        case .saved:     return "Recording saved"
        }
    }
}
