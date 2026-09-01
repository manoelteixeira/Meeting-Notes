import MeetingNotesCore
import SwiftUI

struct TranscriptView: View {
    @Bindable var model: AppModel
    let meeting: Meeting
    var player: AudioPlayerController

    /// Whether playback drags the scroll position along. A manual scroll turns
    /// it off; seeking (or the resume button) turns it back on.
    @State private var isFollowing = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(meeting.transcript) { segment in
                        UtteranceRow(
                            segment: segment,
                            speaker: meeting.speaker(id: segment.speakerID),
                            isCurrent: segment.id == player.currentSegmentID,
                            isSoloPlaying: segment.id == player.soloSegmentID
                                && player.isPlaying,
                            onRename: { name in
                                model.renameSpeaker(segment.speakerID, in: meeting.id, to: name)
                            },
                            onSeek: {
                                player.seek(to: segment.start)
                                isFollowing = true
                            },
                            onPlaySection: { player.playSegment(segment) },
                            onEditText: { text in
                                model.updateSegmentText(segment.id, in: meeting.id, to: text)
                            }
                        )
                        .id(segment.id)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onScrollPhaseChange { _, newPhase in
                // Only user gestures land here; programmatic scrolls report
                // `.animating`, so following never cancels itself.
                if newPhase == .tracking || newPhase == .interacting {
                    isFollowing = false
                }
            }
            .onChange(of: player.currentSegmentID) { _, segmentID in
                guard isFollowing, let segmentID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(segmentID, anchor: .center)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isFollowing, player.isPlaying {
                    Button {
                        isFollowing = true
                        if let segmentID = player.currentSegmentID {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(segmentID, anchor: .center)
                            }
                        }
                    } label: {
                        Label("Resume follow", systemImage: "arrow.down.to.line")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("Scroll with the audio again")
                }
            }
        }
    }
}

private struct UtteranceRow: View {
    let segment: TranscriptSegment
    let speaker: Speaker?
    let isCurrent: Bool
    let isSoloPlaying: Bool
    let onRename: (String) -> Void
    let onSeek: () -> Void
    let onPlaySection: () -> Void
    let onEditText: (String) -> Void

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var isHovering = false
    @FocusState private var editorFocused: Bool

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

                Button(action: onSeek) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .opacity(isHovering ? 1 : 0)
                        Text(MarkdownExporter.timestamp(segment.start))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Play from here")

                Spacer(minLength: 0)

                Button(action: onPlaySection) {
                    Image(systemName: isSoloPlaying ? "pause.circle.fill" : "play.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isSoloPlaying ? 1 : 0)
                .help("Play this section")

                if !isEditing {
                    Button {
                        beginEditing()
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1 : 0)
                    .help("Edit this text")
                }
            }

            if isEditing {
                TextField("", text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($editorFocused)
                    .onSubmit(commitEdit)
                    .onExitCommand { isEditing = false }
            } else {
                Text(segment.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(
            isCurrent ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Edit Text") { beginEditing() }
            Button("Play This Section") { onPlaySection() }
            Button("Play from Here") { onSeek() }
        }
    }

    private func beginEditing() {
        draftText = segment.text
        isEditing = true
        editorFocused = true
    }

    private func commitEdit() {
        onEditText(draftText)
        isEditing = false
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
