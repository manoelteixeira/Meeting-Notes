import MeetingNotesCore
import SwiftUI

struct TranscriptView: View {
    @Bindable var model: AppModel
    let meeting: Meeting

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(meeting.transcript) { segment in
                    UtteranceRow(
                        segment: segment,
                        speaker: meeting.speaker(id: segment.speakerID),
                        onRename: { name in
                            model.renameSpeaker(segment.speakerID, in: meeting.id, to: name)
                        }
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }
}

private struct UtteranceRow: View {
    let segment: TranscriptSegment
    let speaker: Speaker?
    let onRename: (String) -> Void

    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    draftName = speaker?.displayName ?? ""
                    isRenaming = true
                } label: {
                    Text(speaker?.displayName ?? "Unknown speaker")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            SpeakerPalette.color(for: speaker).opacity(0.18),
                            in: Capsule()
                        )
                        .foregroundStyle(SpeakerPalette.color(for: speaker))
                }
                .buttonStyle(.plain)
                .help("Rename this speaker")
                .disabled(speaker == nil || speaker?.isUnknown == true)
                .popover(isPresented: $isRenaming) {
                    SpeakerRenamePopover(name: $draftName) {
                        onRename(draftName)
                        isRenaming = false
                    }
                }

                Text(MarkdownExporter.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(segment.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SpeakerRenamePopover: View {
    @Binding var name: String
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speaker name").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(onCommit)
            Button("Rename", action: onCommit)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }
}
