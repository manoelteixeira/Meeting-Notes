import MeetingNotesCore
import SwiftUI

/// Pinned above the detail pane while a recording runs: how long, how loud,
/// and the way out.
struct RecordingBar: View {
    let recording: RecordingController
    let onStop: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)

            if let startedAt = recording.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(MarkdownExporter.timestamp(context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                }
            }

            LevelMeter(systemImage: "mic.fill", level: recording.microphoneLevel)
                .help("Microphone")
            if let system = recording.systemLevel {
                LevelMeter(systemImage: "speaker.wave.2.fill", level: system)
                    .help("System audio — other apps, such as the call")
            }
            if let notice = recording.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Discard…", role: .destructive) { confirmingDiscard = true }
            Button("Stop", systemImage: "stop.fill", action: onStop)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.08))
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard) {
            Button("Discard Recording", role: .destructive, action: onDiscard)
        } message: {
            Text("The audio recorded so far will be deleted.")
        }
    }
}

struct LevelMeter: View {
    let systemImage: String
    let level: Double
    var width: CGFloat = 70

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Gauge(value: level) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(level > 0.95 ? .red : .green)
                .frame(width: width)
                .animation(.linear(duration: 1.0 / 15), value: level)
        }
    }
}
