import MeetingNotesCore
import SwiftUI

/// Sets up and runs a recording. Stopping turns it into a meeting and opens it.
struct RecordView: View {
    @Bindable var model: AppModel
    @State private var confirmingDiscard = false

    private var recording: RecordingController { model.recording }

    var body: some View {
        VStack(spacing: 28) {
            if recording.isRecording {
                liveStatus
            } else {
                sources
            }

            VStack(spacing: 10) {
                recordButton
                Text(recording.isRecording ? "Stop and Transcribe" : "Start Recording")
                    .font(.headline)
                if recording.isRecording {
                    Button("Discard…", role: .destructive) { confirmingDiscard = true }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Record Meeting")
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard) {
            Button("Discard Recording", role: .destructive) { model.discardRecording() }
        } message: {
            Text("The audio recorded so far will be deleted.")
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Microphone")
                Spacer()
                Text("Always on")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            Toggle(isOn: $model.includeSystemAudio) {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record call audio")
                        Text("Captures other apps, such as a video call")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .padding(14)
        }
        .frame(width: 420)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private var liveStatus: some View {
        VStack(spacing: 18) {
            if let startedAt = recording.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(MarkdownExporter.timestamp(context.date.timeIntervalSince(startedAt)))
                        .font(.system(size: 56, weight: .light))
                        .monospacedDigit()
                }
            }
            HStack(spacing: 24) {
                LevelMeter(systemImage: "mic.fill", level: recording.microphoneLevel, width: 120)
                    .help("Microphone")
                if let system = recording.systemLevel {
                    LevelMeter(systemImage: "speaker.wave.2.fill", level: system, width: 120)
                        .help("System audio — other apps, such as the call")
                }
            }
            if let notice = recording.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if recording.isRecording {
                    await model.stopRecording()
                } else {
                    await model.startRecording()
                }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.quaternary, lineWidth: 4)
                if recording.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 62, height: 62)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.2), value: recording.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording.isRecording ? "Stop and Transcribe" : "Start Recording")
    }
}
