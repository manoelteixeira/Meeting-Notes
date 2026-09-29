import CoreML
import FluidAudio
import Foundation

/// Local speaker diarization via FluidAudio's Sortformer model.
///
/// Sortformer is end-to-end: one network emits per-frame activity for up to
/// four speaker slots, so a one-second reply gets its own slot instead of
/// being clustered into whoever spoke around it. It yields no voiceprints;
/// pair it with `VoiceprintAugmentedDiarizationService` for recognition.
///
/// The model is CoreML, fetched from Hugging Face once and cached on disk;
/// the audio never leaves the Mac. `SortformerDiarizer` is single-use and not
/// thread-safe, and `SortformerModels` carries the input buffers inference
/// writes into, so each call builds a fresh diarizer over fresh buffers around
/// the one loaded `MLModel` (which is safe to share), and runs the synchronous
/// inference off the cooperative pool. Two meetings can then be identified at
/// once without treading on each other.
public final class SortformerDiarizationService: DiarizationService, @unchecked Sendable {

    private let config: SortformerConfig
    private let timelineConfig: DiarizerTimelineConfig
    private let computeUnits: MLComputeUnits
    private let gate = PreparationGate()
    /// Written once under the gate, read-only afterwards.
    private var models: SortformerModels?

    public var requiredSampleRate: Double { 16_000 }

    /// Segment post-processing: spans shorter than three frames are noise,
    /// gaps shorter than four frames are the same turn. Kept short on purpose
    /// so a one-word answer survives.
    public static var defaultTimeline: DiarizerTimelineConfig {
        var timeline = DiarizerTimelineConfig.sortformerDefault
        timeline.minDurationOn = 0.24
        timeline.minDurationOff = 0.32
        return timeline
    }

    public init(
        config: SortformerConfig = .default,
        timelineConfig: DiarizerTimelineConfig = SortformerDiarizationService.defaultTimeline,
        computeUnits: MLComputeUnits = .cpuOnly
    ) {
        self.config = config
        self.timelineConfig = timelineConfig
        self.computeUnits = computeUnits
    }

    /// The default timeline with different minimum span and gap lengths, for tuning.
    public convenience init(minDurationOn: Float?, minDurationOff: Float?) {
        var timeline = Self.defaultTimeline
        if let minDurationOn { timeline.minDurationOn = minDurationOn }
        if let minDurationOff { timeline.minDurationOff = minDurationOff }
        self.init(timelineConfig: timeline)
    }

    public func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws {
        onDownloadProgress(0)
        do {
            try await gate.run { [self] in
                let loaded = try await SortformerModels.loadFromHuggingFace(
                    config: config,
                    computeUnits: computeUnits
                ) { progress in
                    onDownloadProgress(min(max(progress.fractionCompleted, 0), 1))
                }
                models = loaded
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PipelineError(
                code: .modelDownloadFailed,
                message: "The speaker-identification model could not be prepared. "
                    + "Check your internet connection and try again. "
                    + "(\(error.localizedDescription))",
                stage: .diarized
            )
        }
        onDownloadProgress(1)
    }

    public func diarize(
        samples: [Float],
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> DiarizationOutput {
        try await prepare(onDownloadProgress: { _ in })
        try Task.checkCancellation()
        guard let models else {
            throw PipelineError(
                code: .diarizationFailed,
                message: "The speaker-identification model is not loaded.",
                stage: .diarized
            )
        }

        let config = self.config
        let timelineConfig = self.timelineConfig
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        do {
            // Fresh input buffers around the shared MLModel; see the type comment.
            diarizer.initialize(models: try SortformerModels(config: config, main: models.mainModel))
        } catch {
            throw PipelineError(
                code: .diarizationFailed,
                message: "Speaker identification could not allocate its buffers: \(error.localizedDescription)",
                stage: .diarized
            )
        }

        // Inference is synchronous and CPU-bound; a detached task keeps it
        // off the cooperative pool, and cancelling the caller cancels it,
        // which `processComplete` honours between chunks.
        // The timeline itself is not Sendable, so it is reduced to plain
        // segments before leaving the task.
        let work = Task.detached(priority: Task.currentPriority) { () throws -> [DiarizedSegment] in
            let timeline = try diarizer.processComplete(samples) { processed, total, _ in
                guard total > 0 else { return }
                onProgress(min(max(Double(processed) / Double(total), 0), 1))
            }
            return timeline.speakers.values
                .flatMap(\.finalizedSegments)
                .map {
                    DiarizedSegment(
                        speakerID: "S\($0.speakerIndex + 1)",
                        start: TimeInterval($0.startTime),
                        end: TimeInterval($0.endTime)
                    )
                }
                .filter { $0.duration > 0 }
                .sorted { $0.start < $1.start }
        }
        let segments: [DiarizedSegment]
        do {
            segments = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PipelineError(
                code: .diarizationFailed,
                message: "Speaker identification failed: \(error.localizedDescription)",
                stage: .diarized
            )
        }

        onProgress(1)
        return DiarizationOutput(segments: segments)
    }
}
