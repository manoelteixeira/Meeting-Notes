import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Notes prompt composition")
struct NotesPromptTests {

    /// The system prompt exactly as it was when it was a hardcoded literal.
    /// Composing the default template must reproduce it byte-for-byte — this
    /// is the proof that adding customization changed nothing for existing
    /// users.
    private static let frozenDefaultPrompt = """
        You are an expert meeting-notes writer. You are given the transcript of a \
        recorded meeting. Each line is formatted as `[mm:ss] Speaker Name: text`. \
        The transcript comes from automatic speech recognition and automatic \
        speaker separation, so expect occasional misheard words and occasional \
        lines attributed to the wrong speaker.

        Write the notes as Markdown using exactly these four sections, in this \
        order, with these exact headings:

        ## Summary
        ## Key Discussion Points
        ## Decisions
        ## Action Items

        Rules:
        - Start your response with `## Summary`. Do not add a title, a preamble, \
        or any text before or after the four sections.
        - Summary: two to four sentences on what the meeting was about and where \
        it landed.
        - Key Discussion Points: bullets. Group related discussion together \
        rather than replaying the transcript chronologically.
        - Decisions: bullets, each stating what was decided. Write "No explicit \
        decisions were recorded." if there were none.
        - Action Items: GitHub-style task list items, `- [ ] `. Where the owner \
        can be inferred, prefix the task with the speaker's name and an em dash, \
        e.g. `- [ ] Priya — send the revised budget by Friday`. Write \
        "- [ ] No action items were recorded." if there were none.
        - Prefer the speaker names as given. Do not invent participants, \
        decisions, dates, or numbers that are not supported by the transcript.
        - If a passage is too garbled to interpret, leave it out rather than \
        guessing at it.
        """

    @Test("The default template reproduces the original prompt byte-for-byte")
    func defaultMatchesFrozenPrompt() {
        #expect(NotesPrompt.systemPrompt(template: .default) == Self.frozenDefaultPrompt)
        // And the parameterless call means the default.
        #expect(NotesPrompt.systemPrompt() == Self.frozenDefaultPrompt)
    }

    @Test("Custom sections drive the headings, the opening rule, and the count")
    func customSections() {
        let template = NotesTemplate(sections: [
            .init(title: "Overview", guidance: "one paragraph."),
            .init(title: "Risks"),
            .init(title: "Next Steps", guidance: "bullets with owners."),
        ])
        let prompt = NotesPrompt.systemPrompt(template: template)

        #expect(prompt.contains("exactly these three sections, in this order"))
        #expect(prompt.contains("## Overview\n## Risks\n## Next Steps"))
        #expect(prompt.contains("- Start your response with `## Overview`."))
        #expect(prompt.contains("before or after the three sections."))
        #expect(prompt.contains("- Overview: one paragraph."))
        #expect(prompt.contains("- Next Steps: bullets with owners."))
        // A section without guidance gets a heading but no rule bullet.
        #expect(!prompt.contains("- Risks:"))
    }

    @Test("A single section reads as a section, and big counts fall back to digits")
    func countWording() {
        let one = NotesPrompt.systemPrompt(
            template: NotesTemplate(sections: [.init(title: "Summary")])
        )
        #expect(one.contains("exactly these one section, in this order"))
        #expect(one.contains("before or after the one section."))

        let many = NotesTemplate(sections: (1...12).map { .init(title: "Part \($0)") })
        #expect(NotesPrompt.systemPrompt(template: many).contains("exactly these 12 sections"))
    }

    @Test("The anti-hallucination rules survive any template")
    func fixedRulesAlwaysPresent() {
        let prompt = NotesPrompt.systemPrompt(
            template: NotesTemplate(sections: [.init(title: "Whatever")])
        )
        #expect(prompt.contains("Do not invent participants"))
        #expect(prompt.contains("too garbled to interpret"))
    }

    @Test("Additional instructions append as a trailing block, and only then")
    func additionalInstructions() {
        var template = NotesTemplate.default
        template.additionalInstructions = "Write in Portuguese. Keep bullets terse."
        let prompt = NotesPrompt.systemPrompt(template: template)

        #expect(
            prompt == Self.frozenDefaultPrompt
                + "\n\nAdditional instructions:\nWrite in Portuguese. Keep bullets terse."
        )
    }

    @Test("sanitized trims, drops untitled sections, and never goes empty")
    func sanitization() {
        let messy = NotesTemplate(
            sections: [
                .init(title: "  Summary  ", guidance: " short. "),
                .init(title: "   ", guidance: "orphaned guidance"),
            ],
            additionalInstructions: "  be brief  "
        )
        let clean = messy.sanitized()
        #expect(clean.sections == [.init(title: "Summary", guidance: "short.")])
        #expect(clean.additionalInstructions == "be brief")

        // All sections blank: the default sections return, instructions survive.
        let empty = NotesTemplate(
            sections: [.init(title: " ")],
            additionalInstructions: "still here"
        ).sanitized()
        #expect(empty.sections == NotesTemplate.default.sections)
        #expect(empty.additionalInstructions == "still here")
    }

    @Test("Templates round-trip through Codable, ignoring UI identity")
    func codableRoundTrip() throws {
        var template = NotesTemplate.default
        template.sections[0].title = "Overview"
        template.additionalInstructions = "terse"

        let data = try #require(template.encoded())
        let decoded = try JSONDecoder().decode(NotesTemplate.self, from: data)
        #expect(decoded == template)
        // Fresh UUIDs on decode — equality deliberately does not see them.
        #expect(decoded.sections[0].id != template.sections[0].id)
        // The UI-only identity never reaches the persisted JSON.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"id\""))
    }

    @Test("Missing or unreadable stored data falls back to the default")
    func loadFallsBack() {
        #expect(NotesTemplate.load(from: nil) == .default)
        #expect(NotesTemplate.load(from: Data("not json".utf8)) == .default)
        #expect(NotesTemplate.load(from: NotesTemplate.default.encoded()) == .default)
    }
}
