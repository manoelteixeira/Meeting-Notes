import FluidAudio
import Foundation

/// Local speaker diarization via FluidAudio's offline (whole-file) pipeline.
///
/// Models are CoreML and run on the Neural Engine; they are fetched from Hugging
/// Face once on first use and cached on disk afterwards, so nothing but that
/// initial model download ever touches the network — the audio itself never
/// leaves the Mac.
///
/// `OfflineDiarizerManager` is a non-`Sendable` class holding CoreML state that
/// it documents as read-only after initialization, so this wrapper is
/// `@unchecked Sendable` and serializes the one mutating step (model loading)
/// through `PreparationGate`.
public final class FluidAudioDiarizationService: DiarizationService, @unchecked Sendable {

    /// Runs model preparation exactly once, and lets a later call retry if it failed.
    private actor PreparationGate {
        private var task: Task<Void, Error>?

        func run(_ operation: @Sendable @escaping () async throws -> Void) async throws {
            if let existing = task {
                do {
                    return try await existing.value
                } catch {
                    // A previous attempt failed (usually offline); allow a retry.
                    task = nil
                }
            }
            let newTask = Task(operation: operation)
            task = newTask
            do {
                try await newTask.value
            } catch {
                task = nil
                throw error
            }
        }
    }

    private let manager: OfflineDiarizerManager
    private let gate = PreparationGate()

    public var requiredSampleRate: Double { 16_000 }

    public init(config: OfflineDiarizerConfig = .default) {
        self.manager = OfflineDiarizerManager(config: config)
    }

    public func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws {
        onDownloadProgress(0)
        do {
            try await gate.run { [self] in
                try await manager.prepareModels()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PipelineError(
                code: .modelDownloadFailed,
                message: "The speaker-identification models could not be prepared. "
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

        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples) { processed, total in
                guard total > 0 else { return }
                onProgress(min(max(Double(processed) / Double(total), 0), 1))
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
        let segments = result.segments
            .map {
                DiarizedSegment(
                    speakerID: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds)
                )
            }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        // The offline pipeline always builds the per-speaker centroid map; it
        // is the voiceprint used to recognize the same person across meetings.
        return DiarizationOutput(
            segments: segments,
            speakerEmbeddings: result.speakerDatabase ?? [:]
        )
    }
}
