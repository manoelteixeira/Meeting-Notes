import Foundation

/// A speaker discovered by diarization. `id` is the diarizer's cluster label and
/// is stable for the meeting; `displayName` is user-editable.
public struct Speaker: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Label used when no diarization segment could be matched to a text run.
    public static let unknownID = "unknown"

    public var id: String
    public var displayName: String
    /// Index into the app's speaker colour palette, assigned by first appearance.
    public var colorIndex: Int
    /// The person this voice was recognized as, when voice recognition matched
    /// it against the speaker directory. nil for meetings processed before the
    /// feature existed, with recognition off, or for the unknown speaker.
    public var personID: UUID?

    public init(id: String, displayName: String, colorIndex: Int, personID: UUID? = nil) {
        self.id = id
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.personID = personID
    }

    public var isUnknown: Bool { id == Self.unknownID }
}
