import Foundation
import OSLog
import Synchronization

/// A diarizer whose segments come from `primary` and whose voiceprints come
/// from a second, embedding-producing pass over the same audio.
///
/// Both passes run concurrently. The voiceprint pass is best effort: if its
/// models cannot be prepared or it fails, the primary result is returned
/// without embeddings and recognition simply does not happen for that
/// meeting, exactly as when it is switched off.
public final class VoiceprintAugmentedDiarizationService: DiarizationService, Sendable {

    private let primary: any DiarizationService
    private let voiceprints: any DiarizationService
    private let minimumShare: Double
    private let logger = Logger(subsystem: "MeetingNotes", category: "Diarization")

    public var requiredSampleRate: Double { primary.requiredSampleRate }

    public init(
        primary: any DiarizationService,
        voiceprints: any DiarizationService,
        minimumShare: Double = 0.5
    ) {
        precondition(
            primary.requiredSampleRate == voiceprints.requiredSampleRate,
            "Both diarizers must consume the same sample rate"
        )
        self.primary = primary
        self.voiceprints = voiceprints
        self.minimumShare = minimumShare
    }

    public func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws {
        try await primary.prepare { onDownloadProgress($0 / 2) }
        do {
            try await voiceprints.prepare { onDownloadProgress(0.5 + $0 / 2) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The pass will be attempted again at diarize time and skipped if
            // it still cannot load; the transcript does not depend on it.
            logger.warning("Voiceprint models unavailable; recognition will be skipped: \(error.localizedDescription)")
            onDownloadProgress(1)
        }
    }

    public func diarize(
        samples: [Float],
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> DiarizationOutput {
        let tracker = ProgressTracker(report: onProgress)
        async let primaryTask = primary.diarize(samples: samples) { tracker.update(primary: $0) }
        async let voiceprintTask = voiceprintPass(samples: samples, tracker: tracker)

        let (result, reference) = try await (primaryTask, voiceprintTask)
        onProgress(1)

        guard let reference else { return DiarizationOutput(segments: result.segments) }
        let embeddings = VoiceprintMapper.map(
            primary: result.segments,
            reference: reference.segments,
            embeddings: reference.speakerEmbeddings,
            minimumShare: minimumShare
        )
        return DiarizationOutput(segments: result.segments, speakerEmbeddings: embeddings)
    }

    /// The embedding pass, swallowing everything but cancellation.
    private func voiceprintPass(
        samples: [Float],
        tracker: ProgressTracker
    ) async throws -> DiarizationOutput? {
        do {
            return try await voiceprints.diarize(samples: samples) { tracker.update(voiceprints: $0) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Voiceprint pass failed; skipping recognition: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reports the mean of the two passes, synchronously so no update can
    /// land after the caller has moved on, and never runs backwards.
    private final class ProgressTracker: Sendable {
        private let state = Mutex((primary: 0.0, voiceprints: 0.0))
        private let report: @Sendable (Double) -> Void

        init(report: @Sendable @escaping (Double) -> Void) { self.report = report }

        func update(primary: Double) {
            let mean = state.withLock { state in
                state.primary = max(state.primary, primary)
                return (state.primary + state.voiceprints) / 2
            }
            report(mean)
        }

        func update(voiceprints: Double) {
            let mean = state.withLock { state in
                state.voiceprints = max(state.voiceprints, voiceprints)
                return (state.primary + state.voiceprints) / 2
            }
            report(mean)
        }
    }
}
