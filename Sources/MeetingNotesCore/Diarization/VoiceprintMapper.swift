import Foundation

/// Carries voiceprints from one diarizer's clusters onto another's speakers.
///
/// Sortformer separates short interjections that the offline pyannote pass
/// folds into a neighbour, but it produces no embeddings; pyannote does. Each
/// primary speaker takes the embedding of the reference cluster that covers
/// most of its speech. When two primary speakers point at the same cluster the
/// reference could not tell them apart, and its centroid is a blend: it still
/// goes to the speaker who accounts for nearly all of that cluster's time (a
/// one-word reply absorbed into a long turn barely moves the centroid), and to
/// nobody when the cluster is a real mix of two voices.
public enum VoiceprintMapper {

    public static func map(
        primary: [DiarizedSegment],
        reference: [DiarizedSegment],
        embeddings: [String: [Float]],
        minimumShare: Double = 0.5,
        dominantShare: Double = 0.8
    ) -> [String: [Float]] {
        let primaryIDs = Set(primary.map(\.speakerID))
        let referenceTotals = Dictionary(grouping: reference, by: \.speakerID)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }

        // Best reference cluster per primary speaker, with the overlap time.
        var best: [String: (referenceID: String, overlap: Double)] = [:]
        for speakerID in primaryIDs {
            let own = primary.filter { $0.speakerID == speakerID }
            let total = own.reduce(0) { $0 + $1.duration }
            guard total > 0 else { continue }

            var overlapByReference: [String: Double] = [:]
            for segment in own {
                for candidate in reference {
                    let overlap = min(segment.end, candidate.end) - max(segment.start, candidate.start)
                    if overlap > 0 {
                        overlapByReference[candidate.speakerID, default: 0] += overlap
                    }
                }
            }
            guard let top = overlapByReference.max(by: { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }) else { continue }

            if top.value / total >= minimumShare {
                best[speakerID] = (top.key, top.value)
            }
        }

        // Resolve contested clusters in favour of a dominant claimant, if any.
        let claimants = Dictionary(grouping: best, by: \.value.referenceID)
        var mapped: [String: [Float]] = [:]
        for (referenceID, claims) in claimants {
            guard let embedding = embeddings[referenceID], !embedding.isEmpty else { continue }
            let winner: String?
            if claims.count == 1 {
                winner = claims[0].key
            } else {
                let referenceTotal = referenceTotals[referenceID] ?? 0
                let leader = claims.max { $0.value.overlap < $1.value.overlap }!
                winner = referenceTotal > 0 && leader.value.overlap / referenceTotal >= dominantShare
                    ? leader.key
                    : nil
            }
            if let winner { mapped[winner] = embedding }
        }
        return mapped
    }
}
