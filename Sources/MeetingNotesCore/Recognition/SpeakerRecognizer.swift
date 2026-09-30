import FluidAudio
import Foundation

/// Matches one meeting's speaker voiceprints against the known people, purely.
///
/// The diarizer labels speakers "S1", "S2"… per run, so nothing links the same
/// voice across meetings. This takes the per-run centroid embeddings, finds the
/// closest known person for each by cosine distance, and enrolls the rest as
/// new people. `SpeakerDirectory.recognize` wraps this in its actor so the
/// read-match-write cycle is atomic; keeping the logic itself a pure function
/// over values is what makes it exhaustively testable.
public enum SpeakerRecognizer {

    public struct Config: Sendable, Equatable {
        /// Cosine distance below which a voice is the same person. FluidAudio
        /// documents < 0.5 as "high confidence same speaker" and uses 0.65 for
        /// within-run assignment; cross-meeting comparisons face mic and room
        /// drift, and a false merge quietly fuses two people and corrupts the
        /// shared voiceprint, while a false split just leaves a duplicate
        /// unnamed record to rename once — so sit just above the
        /// high-confidence band.
        public var matchThreshold: Float
        /// Weight of the existing embedding when blending in a new meeting's
        /// centroid, matching FluidAudio's own exponential moving average.
        public var emaAlpha: Float
        /// Speakers heard for less than this are ignored entirely: a few
        /// seconds of cross-talk yields a centroid too noisy to match or enroll.
        public var minSpeechDuration: TimeInterval

        public init(
            matchThreshold: Float = 0.55,
            emaAlpha: Float = 0.9,
            minSpeechDuration: TimeInterval = 10
        ) {
            self.matchThreshold = matchThreshold
            self.emaAlpha = emaAlpha
            self.minSpeechDuration = minSpeechDuration
        }
    }

    /// One run-speaker resolved to a person.
    public struct Assignment: Sendable, Equatable {
        /// The diarizer's per-run label, e.g. "S1".
        public var runSpeakerID: String
        public var personID: UUID
        /// The person's name at match time, for auto-applying to the meeting.
        public var personName: String?
        /// true when no known person matched and this voice was newly enrolled.
        public var isNewPerson: Bool
    }

    public struct Outcome: Sendable, Equatable {
        public var assignments: [Assignment]
        /// The full updated roster to persist: existing people (matched ones
        /// re-blended) plus the newly enrolled.
        public var people: [Person]
    }

    public static func recognize(
        embeddings: [String: [Float]],
        speakingTime: [String: TimeInterval],
        people: [Person],
        meetingDate: Date,
        config: Config = Config(),
        now: Date = Date(),
        idGenerator: () -> UUID = UUID.init
    ) -> Outcome {
        let candidates = embeddings
            .filter { id, embedding in
                id != Speaker.unknownID
                    && !embedding.isEmpty
                    && speakingTime[id] ?? 0 >= config.minSpeechDuration
            }
            .keys.sorted()

        // Score every candidate against every person, then match globally
        // best-first: the closest pair wins, and once either side is taken the
        // rest of its pairs are dead. That keeps assignments unique in both
        // directions — two run speakers can never collapse onto one person.
        // A person's distance is that of their nearest voiceprint: each one
        // stands for the voice under one set of conditions (mic, room), and
        // matching any of them is hearing that person.
        struct Pair {
            let candidate: String
            let personIndex: Int
            let printIndex: Int
            let distance: Float
        }
        var pairs: [Pair] = []
        for candidate in candidates {
            let embedding = embeddings[candidate]!
            for (index, person) in people.enumerated() {
                let nearest = person.voiceprints.indices
                    .filter { person.voiceprints[$0].count == embedding.count }
                    .map { ($0, SpeakerUtilities.cosineDistance(embedding, person.voiceprints[$0])) }
                    .filter { $0.1.isFinite }
                    .min { $0.1 < $1.1 }
                guard let (printIndex, distance) = nearest, distance < config.matchThreshold else { continue }
                pairs.append(
                    Pair(candidate: candidate, personIndex: index, printIndex: printIndex, distance: distance)
                )
            }
        }
        pairs.sort {
            ($0.distance, $0.candidate, people[$0.personIndex].id.uuidString)
                < ($1.distance, $1.candidate, people[$1.personIndex].id.uuidString)
        }

        var updated = people
        var assignments: [Assignment] = []
        var matchedCandidates: Set<String> = []
        var takenPeople: Set<Int> = []
        for pair in pairs {
            guard !matchedCandidates.contains(pair.candidate),
                  !takenPeople.contains(pair.personIndex)
            else { continue }
            matchedCandidates.insert(pair.candidate)
            takenPeople.insert(pair.personIndex)

            var person = updated[pair.personIndex]
            // Only the voiceprint that matched drifts toward this meeting, so
            // the headset voice never bleeds into the laptop-mic one.
            let fresh = embeddings[pair.candidate]!
            person.voiceprints[pair.printIndex] = zip(person.voiceprints[pair.printIndex], fresh).map {
                config.emaAlpha * $0 + (1 - config.emaAlpha) * $1
            }
            person.lastHeardAt = max(person.lastHeardAt, meetingDate)
            updated[pair.personIndex] = person

            assignments.append(
                Assignment(
                    runSpeakerID: pair.candidate,
                    personID: person.id,
                    personName: person.name,
                    isNewPerson: false
                )
            )
        }

        // Whoever matched nobody is a voice we have not heard before.
        for candidate in candidates where !matchedCandidates.contains(candidate) {
            let person = Person(
                id: idGenerator(),
                embedding: embeddings[candidate]!,
                createdAt: now,
                lastHeardAt: meetingDate
            )
            updated.append(person)
            assignments.append(
                Assignment(
                    runSpeakerID: candidate,
                    personID: person.id,
                    personName: nil,
                    isNewPerson: true
                )
            )
        }

        assignments.sort { $0.runSpeakerID < $1.runSpeakerID }
        return Outcome(assignments: assignments, people: updated)
    }

    /// Folds `source` into `target`: one person with both records' voiceprints.
    ///
    /// This is how a voice recognized under one set of conditions comes to be
    /// recognized under another — the duplicate a missed match enrolled
    /// brings its voiceprint along. Past `maxVoiceprints`, the two most
    /// similar voiceprints are averaged into one, keeping the most distinct
    /// conditions. The target's name wins, and the dates span both records.
    public static func merge(
        _ source: Person,
        into target: Person,
        maxVoiceprints: Int = Person.maxVoiceprints
    ) -> Person {
        var merged = target
        merged.name = target.name ?? source.name
        merged.createdAt = min(target.createdAt, source.createdAt)
        merged.lastHeardAt = max(target.lastHeardAt, source.lastHeardAt)

        var prints = (target.voiceprints + source.voiceprints).filter { !$0.isEmpty }
        while prints.count > max(maxVoiceprints, 1) {
            var closest: (i: Int, j: Int, distance: Float)?
            for i in prints.indices {
                for j in prints.indices where j > i && prints[i].count == prints[j].count {
                    let distance = SpeakerUtilities.cosineDistance(prints[i], prints[j])
                    if distance.isFinite, closest.map({ distance < $0.distance }) ?? true {
                        closest = (i, j, distance)
                    }
                }
            }
            // Nothing comparable to fuse: drop the oldest-merged extras.
            guard let (i, j, _) = closest else {
                prints.removeLast(prints.count - max(maxVoiceprints, 1))
                break
            }
            prints[i] = zip(prints[i], prints[j]).map { ($0 + $1) / 2 }
            prints.remove(at: j)
        }
        merged.voiceprints = prints
        return merged
    }
}
