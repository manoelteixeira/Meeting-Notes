import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Markdown export")
struct MarkdownExporterTests {

    private func sampleMeeting() -> Meeting {
        Meeting(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Q3 Planning",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 3_725,
            audioFileName: "audio.m4a",
            originalFileName: "q3-planning.m4a",
            status: .completed,
            lastCompletedStage: .noted,
            transcript: [
                TranscriptSegment(start: 0, end: 4, text: "Let's start.", speakerID: "A"),
                TranscriptSegment(start: 65, end: 70, text: "Sounds good.", speakerID: "B"),
            ],
            speakers: [
                Speaker(id: "A", displayName: "Priya", colorIndex: 1),
                Speaker(id: "B", displayName: "Speaker 2", colorIndex: 2),
            ],
            notesMarkdown: "## Summary\n\nA short planning meeting."
        )
    }

    @Test("Timestamps widen from mm:ss to h:mm:ss past an hour")
    func timestampFormatting() {
        #expect(MarkdownExporter.timestamp(0) == "00:00")
        #expect(MarkdownExporter.timestamp(9) == "00:09")
        #expect(MarkdownExporter.timestamp(65) == "01:05")
        #expect(MarkdownExporter.timestamp(3_599) == "59:59")
        #expect(MarkdownExporter.timestamp(3_600) == "1:00:00")
        #expect(MarkdownExporter.timestamp(3_725) == "1:02:05")
        // Nonsense input must not crash or produce garbage.
        #expect(MarkdownExporter.timestamp(-5) == "00:00")
    }

    @Test("Export includes the header, the notes, and the transcript appendix")
    func fullExport() {
        let markdown = MarkdownExporter.export(sampleMeeting())

        #expect(markdown.hasPrefix("# Q3 Planning\n"))
        #expect(markdown.contains("- **Duration:** 1:02:05"))
        #expect(markdown.contains("- **Speakers:** Priya, Speaker 2"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("**[00:00] Priya:** Let's start."))
        #expect(markdown.contains("**[01:05] Speaker 2:** Sounds good."))
        #expect(markdown.hasSuffix("\n"))
        #expect(!markdown.hasSuffix("\n\n"))
    }

    @Test("The transcript appendix can be omitted")
    func notesOnlyExport() {
        let markdown = MarkdownExporter.export(
            sampleMeeting(),
            options: .init(includeNotes: true, includeTranscript: false)
        )

        #expect(markdown.contains("## Summary"))
        #expect(!markdown.contains("## Transcript"))
    }

    @Test("A meeting with no notes still exports its transcript")
    func transcriptOnlyExport() {
        var meeting = sampleMeeting()
        meeting.notesMarkdown = nil

        let markdown = MarkdownExporter.export(meeting)

        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("Let's start."))
    }

    @Test("The prompt transcript is one compact line per utterance")
    func promptTranscript() {
        let transcript = MarkdownExporter.transcriptForPrompt(sampleMeeting())

        #expect(transcript == "[00:00] Priya: Let's start.\n[01:05] Speaker 2: Sounds good.")
    }

    @Test("An unknown speaker id falls back to a readable label")
    func unknownSpeakerLabel() {
        var meeting = sampleMeeting()
        meeting.transcript = [
            TranscriptSegment(start: 0, end: 1, text: "Who said that?", speakerID: "ghost")
        ]

        #expect(MarkdownExporter.transcriptForPrompt(meeting) == "[00:00] Unknown speaker: Who said that?")
    }

    @Test("Suggested file names strip path-hostile characters")
    func fileNameSanitizing() {
        var meeting = sampleMeeting()
        meeting.title = "Budget: Q3/Q4 review?"
        #expect(MarkdownExporter.suggestedFileName(for: meeting) == "Budget- Q3-Q4 review-.md")

        meeting.title = "   "
        #expect(MarkdownExporter.suggestedFileName(for: meeting) == "Meeting Notes.md")
    }
}
