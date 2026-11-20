import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Meeting speaker corrections")
struct MeetingSpeakerEditTests {

    private let person = UUID()

    /// Sandra, then one voice split into speakers 1 and 2, then an unattributed line.
    private func meeting(personFor1: UUID? = nil, personFor2: UUID? = nil) -> Meeting {
        Meeting(
            title: "Mock interview",
            audioFileName: "audio.m4a",
            originalFileName: "mock.m4a",
            transcript: [
                TranscriptSegment(start: 0, end: 2, text: "How does that sound?", speakerID: "0"),
                TranscriptSegment(start: 2, end: 3, text: "Sounds good.", speakerID: "1"),
                TranscriptSegment(start: 21, end: 23, text: "I don't know.", speakerID: "2"),
                TranscriptSegment(start: 24, end: 30, text: "Like most…", speakerID: "1"),
                TranscriptSegment(start: 31, end: 32, text: "Hmm.", speakerID: Speaker.unknownID),
            ],
            speakers: [
                Speaker(id: "0", displayName: "Sandra", colorIndex: 1),
                Speaker(id: "1", displayName: "Manoel", colorIndex: 2, personID: personFor1),
                Speaker(id: "2", displayName: "Manoel", colorIndex: 3, personID: personFor2),
                Speaker(id: Speaker.unknownID, displayName: "Unknown speaker", colorIndex: 0),
            ]
        )
    }

    @Test("Merging moves every line to the target and drops the source")
    func mergeRelabels() {
        var meeting = meeting()
        meeting.mergeSpeaker("2", into: "1")
        #expect(meeting.transcript.map(\.speakerID) == ["0", "1", "1", "1", Speaker.unknownID])
        #expect(meeting.speakers.map(\.id) == ["0", "1", Speaker.unknownID])
        #expect(meeting.speaker(id: "1")?.colorIndex == 2)
        #expect(meeting.speaker(id: "1")?.displayName == "Manoel")
    }

    @Test("The target inherits the source's person only when it has none")
    func mergeInheritsPerson() {
        var meeting = meeting(personFor2: person)
        meeting.mergeSpeaker("2", into: "1")
        #expect(meeting.speaker(id: "1")?.personID == person)

        let other = UUID()
        var linked = self.meeting(personFor1: other, personFor2: person)
        linked.mergeSpeaker("2", into: "1")
        #expect(linked.speaker(id: "1")?.personID == other)
    }

    @Test("Merging with itself, a missing id, or the unknown speaker does nothing")
    func mergeNoOps() {
        let original = meeting()
        for (source, target) in [("1", "1"), ("9", "1"), ("1", "9"),
                                 (Speaker.unknownID, "1"), ("1", Speaker.unknownID)] {
            var meeting = original
            meeting.mergeSpeaker(source, into: target)
            #expect(meeting == original)
        }
    }

    @Test("Reassigning moves one line and keeps a speaker who still has others")
    func reassignOne() {
        var meeting = meeting()
        let line = meeting.transcript[1].id
        meeting.reassignSegment(line, to: "0")
        #expect(meeting.transcript[1].speakerID == "0")
        #expect(meeting.transcript[3].speakerID == "1")
        #expect(meeting.speaker(id: "1") != nil)
    }

    @Test("Reassigning a speaker's only line drops that speaker")
    func reassignEmpties() {
        var meeting = meeting()
        meeting.reassignSegment(meeting.transcript[2].id, to: "1")
        #expect(meeting.speaker(id: "2") == nil)
    }

    @Test("Reassigning to a speaker not in the meeting does nothing")
    func reassignUnknownTarget() {
        let original = meeting()
        var meeting = original
        meeting.reassignSegment(meeting.transcript[1].id, to: "9")
        #expect(meeting == original)
    }

    @Test("Speakers sharing a person collapse into the first")
    func collapse() {
        var meeting = meeting(personFor1: person, personFor2: person)
        meeting.collapseSpeakersSharingPerson()
        #expect(meeting.speakers.map(\.id) == ["0", "1", Speaker.unknownID])
        #expect(!meeting.transcript.contains { $0.speakerID == "2" })
    }

    @Test("Speakers with different or no people stay apart")
    func collapseLeavesOthers() {
        let original = meeting(personFor1: person)
        var meeting = original
        meeting.collapseSpeakersSharingPerson()
        #expect(meeting == original)
    }
}
