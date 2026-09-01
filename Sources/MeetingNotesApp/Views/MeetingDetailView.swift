import AppKit
import MeetingNotesCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Bindable var model: AppModel
    let meeting: Meeting

    @State private var selectedTab = Tab.transcript
    @State private var player = AudioPlayerController()

    enum Tab: Hashable { case transcript, notes }

    private var progress: MeetingProgress? { model.progress[meeting.id] }
    private var isProcessing: Bool { progress?.isRunning == true }

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let code, let message) = meeting.status, !isProcessing {
                FailureBanner(code: code, message: message) {
                    if PipelineError(code: code, message: message).isNotesOnly {
                        model.regenerateNotes(meeting.id)
                    } else {
                        model.reprocess(meeting.id)
                    }
                }
            }
            if meeting.status == .needsModel, !isProcessing {
                NeedsModelBanner()
            }

            content
        }
        .task(id: meeting.id) {
            loadPlayer()
        }
        .onChange(of: isProcessing) { _, running in
            // Reprocessing rewrites the transcript, so reload the segment
            // timings once it settles; until then the old audio must not play.
            if running {
                player.stop()
            } else {
                loadPlayer()
            }
        }
        .onDisappear { player.stop() }
        .navigationTitle(meeting.title)
        .navigationSubtitle(
            "\(MarkdownExporter.timestamp(meeting.duration)) · \(meeting.speakers.count) speakers"
        )
        .toolbar { toolbarContent }
    }

    @ViewBuilder
    private var content: some View {
        if isProcessing {
            ProcessingView(
                meeting: meeting,
                progress: progress ?? MeetingProgress(),
                onCancel: { model.cancelProcessing(meeting.id) }
            )
        } else if meeting.hasTranscript {
            TabView(selection: $selectedTab) {
                TranscriptView(model: model, meeting: meeting, player: player)
                    .tabItem { Text("Transcript") }
                    .tag(Tab.transcript)

                NotesView(model: model, meeting: meeting)
                    .tabItem { Text("Notes") }
                    .tag(Tab.notes)
            }
            .padding(.top, 8)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AudioPlayerBar(player: player)
            }
        } else {
            ContentUnavailableView {
                Label("Not processed yet", systemImage: "waveform.badge.exclamationmark")
            } description: {
                Text("This recording has not been transcribed.")
            } actions: {
                Button("Process Now") { model.reprocess(meeting.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                model.regenerateNotes(meeting.id)
            } label: {
                Label("Generate Notes", systemImage: "sparkles")
            }
            .disabled(isProcessing || !meeting.hasTranscript || !model.hasNotesModel)
            .help(
                model.hasNotesModel
                    ? "Write meeting notes from the transcript"
                    : "Download a notes model in Settings to generate notes"
            )
        }
        ToolbarItem {
            Button {
                export()
            } label: {
                Label("Export Markdown", systemImage: "square.and.arrow.up")
            }
            .disabled(!meeting.hasTranscript)
            .help("Export the notes and transcript as Markdown")
        }
    }

    private func loadPlayer() {
        guard meeting.hasTranscript, !isProcessing else { return }
        player.load(
            url: model.audioURL(for: meeting),
            segments: meeting.transcript,
            fallbackDuration: meeting.duration
        )
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MarkdownExporter.suggestedFileName(for: meeting)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(model.markdown(for: meeting).utf8).write(to: url, options: .atomic)
        } catch {
            model.alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }
}

private struct FailureBanner: View {
    let code: PipelineErrorCode
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry", action: onRetry)
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}

private struct NeedsModelBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
            Text("The transcript is ready. Download a notes model in Settings to write the notes.")
            Spacer(minLength: 8)
            SettingsLink { Text("Open Settings") }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}
