import MeetingNotesCore
import SwiftUI

struct MeetingsView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var renamingID: UUID?
    @State private var draftTitle = ""

    private var filtered: [Meeting] {
        guard !searchText.isEmpty else { return model.meetings }
        return model.meetings.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// "This Week" and "Earlier", leaving out whichever is empty.
    private var sections: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let (recent, earlier) = filtered.reduce(into: ([Meeting](), [Meeting]())) { groups, meeting in
            if calendar.isDate(meeting.createdAt, equalTo: .now, toGranularity: .weekOfYear) {
                groups.0.append(meeting)
            } else {
                groups.1.append(meeting)
            }
        }
        return [("This Week", recent), ("Earlier", earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.meetings) { meeting in
                        NavigationLink(value: Route.meeting(meeting.id)) {
                            MeetingRow(meeting: meeting, progress: model.progress[meeting.id])
                        }
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
            }
        }
        .listStyle(.inset)
        .frame(maxWidth: .readableWidth)
        .frame(maxWidth: .infinity)
        .searchable(text: $searchText, placement: .toolbar)
        .navigationTitle("Meetings")
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView {
                    Label("No meetings yet", systemImage: "tray")
                } description: {
                    Text("Record a meeting or import a recording to get started.")
                } actions: {
                    HStack {
                        Button("Record Meeting", systemImage: "record.circle") {
                            model.path.append(.record)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Import Recording…") { model.path.append(.importRecording) }
                    }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
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
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("·")
                    Text(MarkdownExporter.timestamp(meeting.duration))
                    if !meeting.speakers.isEmpty {
                        Text("·")
                        Text(meeting.speakers.count == 1 ? "1 speaker" : "\(meeting.speakers.count) speakers")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusBadge(status: meeting.status, progress: progress)
        }
        .padding(.vertical, 6)
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
