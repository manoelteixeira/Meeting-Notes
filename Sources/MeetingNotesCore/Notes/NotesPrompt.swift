import Foundation

/// The prompt that turns a speaker-attributed transcript into meeting notes.
///
/// The section headings are fixed so the Notes tab, the Markdown export, and any
/// later parsing all agree on the document's shape.
public enum NotesPrompt {

    public static let systemPrompt = """
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

    /// Wraps the transcript in the user turn.
    public static func userPrompt(
        transcript: String,
        title: String,
        date: Date,
        duration: TimeInterval,
        speakers: [Speaker]
    ) -> String {
        var header = "Meeting title: \(title)\n"
        header += "Date: \(dateFormatter.string(from: date))\n"
        header += "Duration: \(MarkdownExporter.timestamp(duration))\n"
        if !speakers.isEmpty {
            header += "Speakers: \(speakers.map(\.displayName).joined(separator: ", "))\n"
        }
        return """
            \(header)
            Transcript:
            \(transcript)
            """
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()
}
