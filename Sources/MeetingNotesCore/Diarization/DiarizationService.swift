import Foundation

/// Seam between the pipeline and whichever diarization engine labels speakers.
public protocol DiarizationService: Sendable {
    /// Sample rate the engine expects `diarize(samples:)` to be in.
    var requiredSampleRate: Double { get }

    /// Downloads and compiles models if this is the first run. Progress is
    /// reported when the engine exposes it, otherwise only `0` then `1`.
    func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws

    /// Labels speech spans with speaker identities.
    /// - Parameter samples: mono PCM at `requiredSampleRate`.
    func diarize(
        samples: [Float],
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> [DiarizedSegment]
}
