import Foundation

/// A single imported recording plus everything derived from it.
///
/// Persisted verbatim as `meeting.json` next to a copy of the source audio.
public struct Meeting: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// Duration of the audio in seconds. Zero until the file has been probed.
    public var duration: TimeInterval
    /// File name of the audio copy inside the meeting directory, e.g. `audio.m4a`.
    public var audioFileName: String
    /// Name of the file the user originally imported, kept for display only.
    public var originalFileName: String
    /// BCP-47 identifier of the locale used for transcription.
    public var localeIdentifier: String
    public var status: ProcessingStatus
    /// Highest stage that has fully completed, so retries resume rather than restart.
    public var lastCompletedStage: ProcessingStage
    public var transcript: [TranscriptSegment]
    public var speakers: [Speaker]
    public var notesMarkdown: String?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String,
        originalFileName: String,
        localeIdentifier: String = Locale.current.identifier(.bcp47),
        status: ProcessingStatus = .notStarted,
        lastCompletedStage: ProcessingStage = .imported,
        transcript: [TranscriptSegment] = [],
        speakers: [Speaker] = [],
        notesMarkdown: String? = nil,
        schemaVersion: Int = Meeting.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.originalFileName = originalFileName
        self.localeIdentifier = localeIdentifier
        self.status = status
        self.lastCompletedStage = lastCompletedStage
        self.transcript = transcript
        self.speakers = speakers
        self.notesMarkdown = notesMarkdown
        self.schemaVersion = schemaVersion
    }

    public var hasTranscript: Bool { !transcript.isEmpty }
    public var hasNotes: Bool { !(notesMarkdown ?? "").isEmpty }

    public func speaker(id: String) -> Speaker? {
        speakers.first { $0.id == id }
    }

    /// Display name for a speaker id, falling back to "Unknown speaker".
    public func displayName(forSpeaker id: String) -> String {
        speaker(id: id)?.displayName ?? "Unknown speaker"
    }
}
