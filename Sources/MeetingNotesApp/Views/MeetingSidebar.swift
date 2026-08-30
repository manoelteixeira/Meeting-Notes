import MeetingNotesCore
import SwiftUI

struct MeetingSidebar: View {
    @Bindable var model: AppModel
    @Binding var isImporting: Bool
    @State private var renamingID: UUID?
    @State private var draftTitle = ""

    var body: some View {
        List(selection: $model.selectedMeetingID) {
            ForEach(model.meetings) { meeting in
                MeetingRow(
                    meeting: meeting,
                    progress: model.progress[meeting.id]
                )
                .tag(meeting.id)
                .contextMenu {
                    Button("Rename…") {
                        draftTitle = meeting.title
                        renamingID = meeting.id
                    }
                    Button("Reprocess") { model.reprocess(meeting.id) }
                        .disabled(model.progress[meeting.id] != nil)
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(meeting.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem {
                Button {
                    isImporting = true
                } label: {
                    Label("Import Recording", systemImage: "plus")
                }
                .help("Import an audio recording")
            }
        }
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "tray")
            }
        }
        .sheet(isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            RenameSheet(title: $draftTitle) {
                if let renamingID { model.rename(renamingID, to: draftTitle) }
                renamingID = nil
            } onCancel: {
                renamingID = nil
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let progress: MeetingProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text(MarkdownExporter.timestamp(meeting.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            StatusBadge(status: meeting.status, progress: progress)
        }
        .padding(.vertical, 2)
    }
}

private struct StatusBadge: View {
    let status: ProcessingStatus
    let progress: MeetingProgress?

    var body: some View {
        if let progress, progress.isRunning {
            let active = Self.activeStage(progress)
            HStack(spacing: 5) {
                ProgressView(value: active?.fraction ?? nil, total: 1)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 90)
                Text(active?.detail ?? active?.stage.title ?? "Working")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            switch status {
            case .completed:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .needsModel:
                Label("Needs a model", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            case .cancelled:
                Label("Cancelled", systemImage: "stop.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .notStarted, .running:
                Label("Waiting", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The furthest stage that has not yet finished, so the badge tracks the
    /// work actually in flight.
    static func activeStage(_ progress: MeetingProgress) -> PipelineProgress? {
        let unfinished = progress.stages.values.filter { $0.kind != .finished }
        if let latest = unfinished.max(by: { $0.stage < $1.stage }) { return latest }
        return progress.stages.values.max(by: { $0.stage < $1.stage })
    }
}

struct RenameSheet: View {
    @Binding var title: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Meeting").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(onCommit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Rename", action: onCommit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
