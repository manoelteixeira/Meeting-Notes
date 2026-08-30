import Foundation

/// One utterance: contiguous text attributed to a single speaker.
public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// `Speaker.id`, or `Speaker.unknownID` when attribution failed.
    public var speakerID: String

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerID: String = Speaker.unknownID
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speakerID = speakerID
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// A timestamped run of text as produced by a `TranscriptionService`, before
/// any speaker attribution.
public struct TimedTextRun: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// A speaker-labelled time span as produced by a `DiarizationService`.
public struct DiarizedSegment: Sendable, Equatable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}
