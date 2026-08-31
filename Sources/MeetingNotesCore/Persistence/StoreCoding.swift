import Foundation

/// The JSON dialect both on-disk stores share: pretty-printed with sorted keys
/// so the files are diffable and pleasant to open, and ISO 8601 dates with
/// fractional seconds so a save/load round-trip does not visibly shift a
/// timestamp. `ISO8601FormatStyle` is a `Sendable` value type, unlike
/// `ISO8601DateFormatter`.
enum StoreCoding {
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            do {
                return try Date(text, strategy: dateStyle)
            } catch {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Not an ISO 8601 date: \(text)"
                    )
                )
            }
        }
        return decoder
    }()
}
