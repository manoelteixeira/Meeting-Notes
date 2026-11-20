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
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(meeting.transcript.enumerated()), id: \.element.id) { index, segment in
                        UtteranceRow(
                            segment: segment,
                            speaker: meeting.speaker(id: segment.speakerID),
                            otherSpeakers: meeting.speakers
                                .filter { !$0.isUnknown && $0.id != segment.speakerID }
                                .map { ($0, meeting.menuLabel(for: $0)) },
                            isTrailing: isTrailing(segment.speakerID),
                            showsHeader: index == 0
                                || meeting.transcript[index - 1].speakerID != segment.speakerID,
                            isCurrent: segment.id == player.currentSegmentID,
                            isSoloPlaying: segment.id == player.soloSegmentID
                                && player.isPlaying,
                            onRename: { name in
                                model.renameSpeaker(segment.speakerID, in: meeting.id, to: name)
                            },
                            onMerge: { targetID in
                                model.mergeSpeaker(segment.speakerID, into: targetID, in: meeting.id)
                            },
                            onAssign: { speakerID in
                                model.reassignSegment(segment.id, to: speakerID, in: meeting.id)
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
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
                .frame(maxWidth: .readableWidth)
                .frame(maxWidth: .infinity)
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

    /// Speakers alternate sides in order of first appearance and keep their
    /// side for the whole meeting; the unknown speaker stays on the left.
    private func isTrailing(_ speakerID: String) -> Bool {
        guard speakerID != Speaker.unknownID,
              let position = meeting.speakers
                  .filter({ !$0.isUnknown })
                  .firstIndex(where: { $0.id == speakerID })
        else { return false }
        return position % 2 == 1
    }
}

private struct UtteranceRow: View {
    let segment: TranscriptSegment
    let speaker: Speaker?
    /// The meeting's other named speakers, to merge into or assign this line to.
    let otherSpeakers: [(speaker: Speaker, label: String)]
    let isTrailing: Bool
    let showsHeader: Bool
    let isCurrent: Bool
    let isSoloPlaying: Bool
    let onRename: (String) -> Void
    let onMerge: (String) -> Void
    let onAssign: (String) -> Void
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
        HStack(spacing: 0) {
            if isTrailing { Spacer(minLength: 60) }
            VStack(alignment: isTrailing ? .trailing : .leading, spacing: 4) {
                if showsHeader {
                    header
                }
                HStack(alignment: .top, spacing: 6) {
                    if isTrailing { controls }
                    bubble
                    if !isTrailing { controls }
                }
            }
            if !isTrailing { Spacer(minLength: 60) }
        }
        .padding(.top, showsHeader ? 10 : 0)
        .frame(maxWidth: .infinity)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Edit Text") { beginEditing() }
            Button("Play This Section") { onPlaySection() }
            Button("Play from Here") { onSeek() }
            if !otherSpeakers.isEmpty {
                Menu("Assign to") {
                    ForEach(otherSpeakers, id: \.speaker.id) { other in
                        Button(other.label) { onAssign(other.speaker.id) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isTrailing { timestamp }
            nameChip
            if !isTrailing { timestamp }
        }
    }

    private var nameChip: some View {
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
            SpeakerRenamePopover(name: $draftName, otherSpeakers: otherSpeakers) {
                onRename(draftName)
                isRenaming = false
            } onMerge: { targetID in
                onMerge(targetID)
                isRenaming = false
            }
        }
    }

    private var timestamp: some View {
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
    }

    /// Play-section and edit buttons, shown beside the bubble on hover so they
    /// stay reachable on rows without a header.
    private var controls: some View {
        VStack(spacing: 6) {
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
        .padding(.top, 8)
    }

    private var bubble: some View {
        Group {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            SpeakerPalette.color(for: speaker).opacity(isCurrent ? 0.24 : 0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(isCurrent ? 0.6 : 0), lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
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
    let otherSpeakers: [(speaker: Speaker, label: String)]
    let onCommit: () -> Void
    let onMerge: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speaker name").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(onCommit)
            Button("Rename", action: onCommit)
                .keyboardShortcut(.defaultAction)
            if !otherSpeakers.isEmpty {
                Divider()
                Text("Same person as").font(.caption).foregroundStyle(.secondary)
                // Merge, rather than rename, when the diarizer split one voice:
                // every line moves to the chosen speaker.
                MergeTargetList(targets: otherSpeakers, onSelect: onMerge)
            }
        }
        .padding(14)
    }
}

/// The meeting's other speakers as chips, each a merge target.
private struct MergeTargetList: View {
    let targets: [(speaker: Speaker, label: String)]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(targets, id: \.speaker.id) { target in
                let speaker = target.speaker
                Button {
                    onSelect(speaker.id)
                } label: {
                    Text(target.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SpeakerPalette.color(for: speaker).opacity(0.18), in: Capsule())
                        .foregroundStyle(SpeakerPalette.color(for: speaker))
                }
                .buttonStyle(.plain)
                .help("Merge this speaker into \(speaker.displayName)")
            }
        }
    }
}
