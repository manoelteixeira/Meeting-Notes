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

    // MARK: - Speaker corrections

    /// Folds one speaker into another after the diarizer split a single voice:
    /// every utterance moves to `targetID`, which keeps its name and colour and
    /// inherits the source's person link if it had none.
    public mutating func mergeSpeaker(_ sourceID: String, into targetID: String) {
        guard sourceID != targetID,
              sourceID != Speaker.unknownID, targetID != Speaker.unknownID,
              let source = speaker(id: sourceID),
              let targetIndex = speakers.firstIndex(where: { $0.id == targetID })
        else { return }
        for index in transcript.indices where transcript[index].speakerID == sourceID {
            transcript[index].speakerID = targetID
        }
        if speakers[targetIndex].personID == nil {
            speakers[targetIndex].personID = source.personID
        }
        speakers.removeAll { $0.id == sourceID }
    }

    /// Attributes one utterance to a different speaker. A speaker left with no
    /// utterances is dropped so its chip disappears.
    public mutating func reassignSegment(_ segmentID: UUID, to speakerID: String) {
        guard speaker(id: speakerID) != nil,
              let index = transcript.firstIndex(where: { $0.id == segmentID })
        else { return }
        let previous = transcript[index].speakerID
        guard previous != speakerID else { return }
        transcript[index].speakerID = speakerID
        if previous != Speaker.unknownID,
           !transcript.contains(where: { $0.speakerID == previous }) {
            speakers.removeAll { $0.id == previous }
        }
    }

    /// Merges speakers linked to the same person into the first of them, as
    /// happens once two split voices are merged in the speaker directory.
    public mutating func collapseSpeakersSharingPerson() {
        var firstForPerson: [UUID: String] = [:]
        for speaker in speakers {
            guard let personID = speaker.personID else { continue }
            if let survivor = firstForPerson[personID] {
                mergeSpeaker(speaker.id, into: survivor)
            } else {
                firstForPerson[personID] = speaker.id
            }
        }
    }
}
