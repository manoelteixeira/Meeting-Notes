import Foundation

/// A person identified by voice across meetings.
///
/// The embedding is the 256-dimension speaker centroid the diarizer produces
/// for one meeting, blended with earlier meetings' centroids as more of this
/// voice is heard. It is derived data, computed and stored on this Mac only.
public struct Person: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// nil until the user names them; shown as "Unnamed speaker".
    public var name: String?
    public var embedding: [Float]
    public var createdAt: Date
    /// When this voice was last heard — the meeting's date, not the wall clock,
    /// so reprocessing an old recording does not claim the voice was heard today.
    public var lastHeardAt: Date

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        embedding: [Float],
        createdAt: Date = Date(),
        lastHeardAt: Date
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.createdAt = createdAt
        self.lastHeardAt = lastHeardAt
    }
}
