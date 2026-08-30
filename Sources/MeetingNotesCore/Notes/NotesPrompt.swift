import Foundation

/// The prompt that turns a speaker-attributed transcript into meeting notes.
///
/// The section headings and per-section rules come from the user's
/// `NotesTemplate`; the scaffolding around them — the exact-headings mandate
/// and the anti-hallucination rules — is fixed, so the model is always told
/// precisely what shape to produce.
public enum NotesPrompt {

    public static func systemPrompt(template: NotesTemplate = .default) -> String {
        let template = template.sanitized()
        let sections = template.sections
        let count = countWord(sections.count)
        let noun = sections.count == 1 ? "section" : "sections"

        var rules: [String] = []
        rules.append(
            "Start your response with `## \(sections[0].title)`. Do not add a "
                + "title, a preamble, or any text before or after the \(count) \(noun)."
        )
        for section in sections where !section.guidance.isEmpty {
            rules.append("\(section.title): \(section.guidance)")
        }
        rules.append(
            "Prefer the speaker names as given. Do not invent participants, "
                + "decisions, dates, or numbers that are not supported by the transcript."
        )
        rules.append(
            "If a passage is too garbled to interpret, leave it out rather than "
                + "guessing at it."
        )

        var prompt = """
            You are an expert meeting-notes writer. You are given the transcript of a \
            recorded meeting. Each line is formatted as `[mm:ss] Speaker Name: text`. \
            The transcript comes from automatic speech recognition and automatic \
            speaker separation, so expect occasional misheard words and occasional \
            lines attributed to the wrong speaker.

            Write the notes as Markdown using exactly these \(count) \(noun), in this \
            order, with these exact headings:

            \(sections.map { "## \($0.title)" }.joined(separator: "\n"))

            Rules:
            \(rules.map { "- \($0)" }.joined(separator: "\n"))
            """

        if !template.additionalInstructions.isEmpty {
            prompt += "\n\nAdditional instructions:\n\(template.additionalInstructions)"
        }
        return prompt
    }

    /// The section-count words the default and near-default templates need,
    /// spelled out the way the original prompt did; larger counts fall back
    /// to digits.
    private static func countWord(_ count: Int) -> String {
        let words = [
            "zero", "one", "two", "three", "four", "five",
            "six", "seven", "eight", "nine", "ten",
        ]
        return words.indices.contains(count) ? words[count] : String(count)
    }

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
