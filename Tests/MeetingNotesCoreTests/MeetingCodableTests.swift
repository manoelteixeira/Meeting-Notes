import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Meeting persistence format")
struct MeetingCodableTests {

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @Test("A fully populated meeting round-trips unchanged")
    func roundTrip() throws {
        let original = Meeting(
            title: "Retro",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1_800,
            audioFileName: "audio.m4a",
            originalFileName: "retro.m4a",
            localeIdentifier: "en-US",
            status: .completed,
            lastCompletedStage: .noted,
            transcript: [TranscriptSegment(start: 0, end: 3, text: "Hi", speakerID: "A")],
            speakers: [Speaker(id: "A", displayName: "Priya", colorIndex: 1)],
            notesMarkdown: "## Summary\n\nAll good."
        )

        let decoded = try decoder.decode(Meeting.self, from: encoder.encode(original))

        #expect(decoded == original)
    }

    @Test("A pre-recognition speaker without personID still decodes")
    func oldSpeakerFormatDecodes() throws {
        // Written by app versions that predate voice recognition.
        let json = Data(#"{"id": "A", "displayName": "Priya", "colorIndex": 1}"#.utf8)

        let decoded = try decoder.decode(Speaker.self, from: json)

        #expect(decoded == Speaker(id: "A", displayName: "Priya", colorIndex: 1))
        #expect(decoded.personID == nil)
    }

    @Test("A speaker linked to a person round-trips with the link intact")
    func linkedSpeakerRoundTrip() throws {
        let personID = UUID()
        let original = Speaker(id: "A", displayName: "Priya", colorIndex: 1, personID: personID)

        let decoded = try decoder.decode(Speaker.self, from: encoder.encode(original))

        #expect(decoded == original)
        #expect(decoded.personID == personID)
    }

    @Test("Every processing status round-trips, including its payload")
    func statusRoundTrip() throws {
        let statuses: [ProcessingStatus] = [
            .notStarted,
            .running,
            .needsModel,
            .completed,
            .cancelled,
            .failed(code: .notesModelNotInstalled, message: "No model installed"),
        ]

        for status in statuses {
            let decoded = try decoder.decode(
                ProcessingStatus.self,
                from: encoder.encode(status)
            )
            #expect(decoded == status)
        }
    }

    @Test("Stages compare in pipeline order")
    func stageOrdering() {
        #expect(ProcessingStage.imported < .decoded)
        #expect(ProcessingStage.decoded < .transcribed)
        #expect(ProcessingStage.transcribed < .diarized)
        #expect(ProcessingStage.diarized < .merged)
        #expect(ProcessingStage.merged < .noted)
        #expect(ProcessingStage.allCases.count == 6)
    }

    @Test("New meetings carry the current schema version")
    func schemaVersion() {
        let meeting = Meeting(title: "T", audioFileName: "audio.m4a", originalFileName: "t.m4a")
        #expect(meeting.schemaVersion == Meeting.currentSchemaVersion)
    }

    @Test("Notes-stage failures are flagged as retryable without redoing the transcript")
    func notesOnlyRetry() {
        #expect(PipelineError(code: .notesModelNotInstalled, message: "").isNotesOnly)
        #expect(PipelineError(code: .notesModelLoadFailed, message: "").isNotesOnly)
        #expect(PipelineError(code: .notesTruncated, message: "").isNotesOnly)
        #expect(!PipelineError(code: .unsupportedAudio, message: "").isNotesOnly)
        #expect(!PipelineError(code: .transcriptionFailed, message: "").isNotesOnly)
    }
}
