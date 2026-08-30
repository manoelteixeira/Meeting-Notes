import MeetingNotesCore
import SwiftUI

/// Stage checklist shown while a meeting is being processed.
struct ProcessingView: View {
    let meeting: Meeting
    let progress: MeetingProgress
    let onCancel: () -> Void

    /// `.imported` is not work, so it is not shown.
    private static let visibleStages: [ProcessingStage] =
        [.decoded, .transcribed, .diarized, .merged, .noted]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.visibleStages, id: \.self) { stage in
                StageRow(stage: stage, progress: progress.stage(stage))
            }

            if !progress.streamedNotes.isEmpty {
                Divider()
                ScrollView {
                    Text(progress.streamedNotes)
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StageRow: View {
    let stage: ProcessingStage
    let progress: PipelineProgress?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(progress?.detail ?? stage.title)
                    .foregroundStyle(progress == nil ? .secondary : .primary)
                if let progress, progress.kind != .finished {
                    ProgressView(value: progress.fraction, total: 1)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch progress?.kind {
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .some:
            ProgressView().controlSize(.small)
        case nil:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
