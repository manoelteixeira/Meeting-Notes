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

    private let manager: OfflineDiarizerManager
    private let gate = PreparationGate()

    public var requiredSampleRate: Double { 16_000 }

    public init(config: OfflineDiarizerConfig = .default) {
        self.manager = OfflineDiarizerManager(config: config)
    }

    /// The default configuration with selected clustering knobs overridden.
    ///
    /// - `clusteringThreshold`: the agglomerative cut; lower values separate
    ///   similar-sounding voices more readily.
    /// - `numSpeakers` / `minSpeakers` / `maxSpeakers`: bounds on the speaker
    ///   count; when the estimate falls outside them the embeddings are
    ///   re-clustered to the nearest bound.
    /// - `Fa` / `Fb`: VBx warm-start weights (acoustic vs. prior). A higher
    ///   `Fa` trusts the embeddings more and keeps small clusters alive.
    public convenience init(
        clusteringThreshold: Double? = nil,
        numSpeakers: Int? = nil,
        minSpeakers: Int? = nil,
        maxSpeakers: Int? = nil,
        Fa: Double? = nil,
        Fb: Double? = nil
    ) {
        var config = OfflineDiarizerConfig.default
        if let clusteringThreshold { config.clustering.threshold = clusteringThreshold }
        if let numSpeakers { config.clustering.numSpeakers = numSpeakers }
        if let minSpeakers { config.clustering.minSpeakers = minSpeakers }
        if let maxSpeakers { config.clustering.maxSpeakers = maxSpeakers }
        if let Fa { config.clustering.warmStartFa = Fa }
        if let Fb { config.clustering.warmStartFb = Fb }
        self.init(config: config)
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
