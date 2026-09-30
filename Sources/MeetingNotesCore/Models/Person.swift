import Foundation

/// A person identified by voice across meetings.
///
/// Each voiceprint is a 256-dimension speaker centroid the diarizer produces
/// for one meeting, blended with later meetings' centroids as more of this
/// voice is heard. A person starts with one; merging a duplicate record in
/// adds its voiceprints, so the same voice heard through a different mic or
/// room keeps matching. It is derived data, computed and stored on this Mac only.
public struct Person: Codable, Sendable, Equatable, Identifiable {
    /// More voiceprints mean more chances of a false match, so a merge that
    /// would exceed this fuses the two most similar ones instead.
    public static let maxVoiceprints = 5

    public var id: UUID
    /// nil until the user names them; shown as "Unnamed speaker".
    public var name: String?
    /// Never empty for a person the recognizer created.
    public var voiceprints: [[Float]]
    public var createdAt: Date
    /// When this voice was last heard — the meeting's date, not the wall clock,
    /// so reprocessing an old recording does not claim the voice was heard today.
    public var lastHeardAt: Date

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        voiceprints: [[Float]],
        createdAt: Date = Date(),
        lastHeardAt: Date
    ) {
        self.id = id
        self.name = name
        self.voiceprints = voiceprints
        self.createdAt = createdAt
        self.lastHeardAt = lastHeardAt
    }

    /// A person with a single voiceprint, as enrollment creates them.
    public init(
        id: UUID = UUID(),
        name: String? = nil,
        embedding: [Float],
        createdAt: Date = Date(),
        lastHeardAt: Date
    ) {
        self.init(
            id: id,
            name: name,
            voiceprints: [embedding],
            createdAt: createdAt,
            lastHeardAt: lastHeardAt
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, voiceprints, createdAt, lastHeardAt
        /// Written before a person could hold several voiceprints; read only.
        case embedding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let voiceprints = try container.decodeIfPresent([[Float]].self, forKey: .voiceprints) {
            self.voiceprints = voiceprints
        } else {
            voiceprints = [try container.decode([Float].self, forKey: .embedding)]
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastHeardAt = try container.decode(Date.self, forKey: .lastHeardAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(voiceprints, forKey: .voiceprints)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastHeardAt, forKey: .lastHeardAt)
    }
}
