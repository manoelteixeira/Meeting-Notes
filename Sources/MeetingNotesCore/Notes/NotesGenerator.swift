import Foundation

/// Notes as returned by the model, plus whether generation was cut short.
public struct GeneratedNotes: Sendable, Equatable {
    public var markdown: String
    /// The model hit its token cap; the notes end mid-thought.
    public var isTruncated: Bool

    public init(markdown: String, isTruncated: Bool) {
        self.markdown = markdown
        self.isTruncated = isTruncated
    }
}

/// Turns a completed meeting transcript into Markdown notes.
///
/// Provider-agnostic: it owns the prompt and the shape of the result, and
/// leaves running the model to whichever `NotesService` it was given.
public struct NotesGenerator: Sendable {

    private let service: any NotesService

    public init(service: any NotesService) {
        self.service = service
    }

    /// - Parameter onDelta: called with incremental text as it is generated;
    ///   pass `nil` to accumulate silently.
    public func generate(
        for meeting: Meeting,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> GeneratedNotes {
        guard meeting.hasTranscript else {
            throw PipelineError(
                code: .notesFailed,
                message: "There is no transcript to summarize yet.",
                stage: .noted
            )
        }

        let user = NotesPrompt.userPrompt(
            transcript: MarkdownExporter.transcriptForPrompt(meeting),
            title: meeting.title,
            date: meeting.createdAt,
            duration: meeting.duration,
            speakers: meeting.speakers
        )

        let completion = try await service.generate(
            system: NotesPrompt.systemPrompt,
            user: user,
            onDelta: onDelta
        )

        return GeneratedNotes(
            markdown: completion.text.trimmingCharacters(in: .whitespacesAndNewlines),
            isTruncated: completion.isTruncated
        )
    }
}
