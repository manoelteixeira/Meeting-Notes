import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Speaker recognition")
struct SpeakerRecognizerTests {

    /// Unit vector whose cosine similarity to [1, 0] is exactly `similarity`,
    /// making the resulting cosine distance `1 - similarity`.
    private func vector(similarity: Float) -> [Float] {
        [similarity, (1 - similarity * similarity).squareRoot()]
    }

    private let reference: [Float] = [1, 0]

    private func person(
        name: String? = nil,
        embedding: [Float],
        lastHeardAt: Date = .distantPast
    ) -> Person {
        Person(name: name, embedding: embedding, lastHeardAt: lastHeardAt)
    }

    private func sequentialIDs() -> () -> UUID {
        var next = 0
        return {
            next += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", next))!
        }
    }

    // Ample speaking time so the duration gate never interferes unless a test
    // is specifically about it.
    private let ampleTime: [String: TimeInterval] = ["S1": 60, "S2": 60, "S3": 60]

    @Test("A close voice matches the known person")
    func closeVoiceMatches() {
        let priya = person(name: "Priya", embedding: reference)
        let outcome = SpeakerRecognizer.recognize(
            embeddings: ["S1": vector(similarity: 0.9)],
            speakingTime: ampleTime,
            people: [priya],
            meetingDate: Date()
        )

        #expect(outcome.assignments == [
            .init(runSpeakerID: "S1", personID: priya.id, personName: "Priya", isNewPerson: false)
        ])
        #expect(outcome.people.count == 1)
    }

    @Test("A distant voice enrolls as a new person instead of matching")
    func distantVoiceEnrolls() {
        let priya = person(name: "Priya", embedding: reference)
        let ids = sequentialIDs()
        let outcome = SpeakerRecognizer.recognize(
            embeddings: ["S1": vector(similarity: 0.2)],  // distance 0.8
            speakingTime: ampleTime,
            people: [priya],
            meetingDate: Date(),
            idGenerator: ids
        )

        #expect(outcome.assignments.count == 1)
        #expect(outcome.assignments[0].isNewPerson)
        #expect(outcome.assignments[0].personName == nil)
        #expect(outcome.people.count == 2)
        #expect(outcome.people[1].name == nil)
    }

    @Test("The threshold separates just-below from just-above")
    func thresholdBoundary() {
        let priya = person(name: "Priya", embedding: reference)

        // Distance 0.54: inside the default 0.55 threshold.
        let matched = SpeakerRecognizer.recognize(
            embeddings: ["S1": vector(similarity: 0.46)],
            speakingTime: ampleTime,
            people: [priya],
            meetingDate: Date()
        )
        #expect(matched.assignments[0].isNewPerson == false)

        // Distance 0.56: outside.
        let missed = SpeakerRecognizer.recognize(
            embeddings: ["S1": vector(similarity: 0.44)],
            speakingTime: ampleTime,
            people: [priya],
            meetingDate: Date()
        )
        #expect(missed.assignments[0].isNewPerson)
    }

    @Test("Two run speakers cannot claim the same person; the closer one wins")
    func greedyUniqueness() {
        let priya = person(name: "Priya", embedding: reference)
        let outcome = SpeakerRecognizer.recognize(
            embeddings: [
                "S1": vector(similarity: 0.8),  // distance 0.2
                "S2": vector(similarity: 0.95), // distance 0.05 — closer
            ],
            speakingTime: ampleTime,
            people: [priya],
            meetingDate: Date(),
            idGenerator: sequentialIDs()
        )

        let byRun = Dictionary(uniqueKeysWithValues: outcome.assignments.map { ($0.runSpeakerID, $0) })
        #expect(byRun["S2"]?.personID == priya.id)
        #expect(byRun["S2"]?.isNewPerson == false)
        #expect(byRun["S1"]?.isNewPerson == true)
        #expect(outcome.people.count == 2)
    }

    @Test("A match blends the embeddings with the documented EMA weights")
    func emaBlending() {
        let old: [Float] = [1, 0]
        let fresh: [Float] = [0.9, (1 - 0.81 as Float).squareRoot()]
        let priya = person(name: "Priya", embedding: old)
        let outcome = SpeakerRecognizer.recognize(
            embeddings: ["S1": fresh],
            speakingTime: ampleTime,
            people: [priya],
            meetingDate: Date()
        )

        let alpha: Float = 0.9
        let expected = zip(old, fresh).map { alpha * $0 + (1 - alpha) * $1 }
        #expect(outcome.people[0].embedding == expected)
    }

    @Test("New people carry the injected id, creation time, and meeting date")
    func newPersonMetadata() {
        let now = Date(timeIntervalSince1970: 2_000)
        let meetingDate = Date(timeIntervalSince1970: 1_000)
        let outcome = SpeakerRecognizer.recognize(
            embeddings: ["S1": reference],
            speakingTime: ampleTime,
            people: [],
            meetingDate: meetingDate,
            now: now,
            idGenerator: sequentialIDs()
        )

        let enrolled = outcome.people[0]
        #expect(enrolled.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(enrolled.createdAt == now)
        #expect(enrolled.lastHeardAt == meetingDate)
        #expect(enrolled.embedding == reference)
    }

    @Test("Brief speakers are ignored — neither matched nor enrolled")
    func durationGate() {
        let priya = person(name: "Priya", embedding: reference)
        let outcome = SpeakerRecognizer.recognize(
            embeddings: ["S1": reference],
            speakingTime: ["S1": 5],  // below the 10 s default
            people: [priya],
            meetingDate: Date()
        )

        #expect(outcome.assignments.isEmpty)
        #expect(outcome.people == [priya])
    }

    @Test("The unknown speaker and mismatched dimensions never match")
    func unknownAndMismatchedSkipped() {
        let priya = person(name: "Priya", embedding: [1, 0, 0])  // 3-d vs 2-d below
        let outcome = SpeakerRecognizer.recognize(
            embeddings: [
                Speaker.unknownID: reference,
                "S1": reference,
            ],
            speakingTime: [Speaker.unknownID: 60, "S1": 60],
            people: [priya],
            meetingDate: Date(),
            idGenerator: sequentialIDs()
        )

        // Unknown produced nothing; S1 could not be compared, so it enrolled.
        #expect(outcome.assignments.map(\.runSpeakerID) == ["S1"])
        #expect(outcome.assignments[0].isNewPerson)
    }

    @Test("Hearing an old recording never moves lastHeardAt backwards")
    func lastHeardAtNeverRegresses() {
        let recent = Date(timeIntervalSince1970: 5_000)
        let priya = person(name: "Priya", embedding: reference, lastHeardAt: recent)
        let outcome = SpeakerRecognizer.recognize(
            embeddings: ["S1": vector(similarity: 0.9)],
            speakingTime: ampleTime,
            people: [priya],
            meetingDate: Date(timeIntervalSince1970: 1_000),
            idGenerator: sequentialIDs()
        )

        #expect(outcome.people[0].lastHeardAt == recent)
    }
}
