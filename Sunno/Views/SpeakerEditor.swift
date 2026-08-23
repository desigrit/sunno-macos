import SwiftUI

/// Naming a speaker, marking them as you, or folding two together.
///
/// A sheet rather than a popover. All three actions rewrite history across the whole
/// transcript, and a popover that can be dismissed by clicking anywhere is the wrong weight
/// for something that changes who is recorded as having said what.
struct SpeakerEditor: View {
    let speaker: SpeakerRow
    let others: [SpeakerRow]
    let onFinish: (Action) -> Void

    enum Action {
        case rename(String)
        case setSelf(Bool)
        case merge(into: Int)
        case cancel
    }

    @State private var name: String = ""
    @State private var isSelf: Bool = false
    @State private var mergeTarget: Int?

    private var candidates: [SpeakerRow] {
        others.filter { $0.id != speaker.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit speaker")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(speaker.label, text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Naming someone pins their voice profile, which stops it drifting and "
                     + "makes them easier to recognise next time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("This is me", isOn: $isSelf)
                .toggleStyle(.checkbox)
            Text("Your own lines render fainter and are labelled You. On a Whisper model they "
                 + "also carry a clarity score.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !candidates.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Merge into").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: $mergeTarget) {
                        Text("Nobody").tag(Int?.none)
                        ForEach(candidates) { other in
                            Text(other.displayLabel).tag(Int?.some(other.id))
                        }
                    }
                    .labelsHidden()
                    Text("Use this when one person has been split across two labels.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onFinish(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            // An auto-assigned "Speaker 3" is a placeholder rather than a name, so the field
            // starts empty and shows it as the prompt instead. Otherwise the first thing
            // someone has to do is delete text the app wrote.
            name = speaker.named ? speaker.label : ""
            isSelf = speaker.isSelf
        }
    }

    /// One action per save, in a deliberate order.
    ///
    /// Merging destroys the id being edited, so a rename issued alongside it would apply to
    /// a speaker that no longer exists. Merge therefore wins outright and the other fields
    /// are ignored when it is set.
    private func save() {
        if let target = mergeTarget {
            onFinish(.merge(into: target))
            return
        }
        if isSelf != speaker.isSelf {
            onFinish(.setSelf(isSelf))
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != speaker.label {
            onFinish(.rename(trimmed))
            return
        }
        onFinish(.cancel)
    }
}
