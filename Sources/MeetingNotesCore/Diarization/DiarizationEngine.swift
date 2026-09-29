import Foundation

/// The speaker-identification models the app can run. Both are local.
public enum DiarizationEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// NVIDIA's Sortformer: end-to-end, up to four speakers, and good at
    /// short interjections a clustering pipeline folds into a neighbour.
    case sortformer
    /// pyannote's offline pipeline: segmentation, embeddings and clustering,
    /// no speaker cap, and the only one that yields voiceprints.
    case pyannote

    public static let `default` = DiarizationEngine.sortformer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sortformer: "Sortformer"
        case .pyannote: "pyannote"
        }
    }

    /// Builds the service for this engine.
    ///
    /// Sortformer produces no voiceprints, so with `withVoiceprints` it is
    /// paired with a pyannote pass whose embeddings are carried across by
    /// time overlap; pyannote alone already has them.
    public func makeService(withVoiceprints: Bool) -> any DiarizationService {
        switch self {
        case .sortformer:
            let primary = SortformerDiarizationService()
            guard withVoiceprints else { return primary }
            return VoiceprintAugmentedDiarizationService(
                primary: primary,
                voiceprints: FluidAudioDiarizationService()
            )
        case .pyannote:
            return FluidAudioDiarizationService()
        }
    }
}
