import Foundation

/// On-disk storage for meetings.
///
/// Each meeting is a directory under Application Support holding `meeting.json`
/// and a copy of the imported audio, so the library keeps working after the
/// user moves or deletes the original recording:
///
/// ```
/// ~/Library/Application Support/MeetingNotes/Meetings/<uuid>/
///     meeting.json
///     audio.m4a
/// ```
///
/// Plain Codable JSON rather than SwiftData: the documents are small, easy to
/// inspect, and trivially versioned via `Meeting.schemaVersion`.
public actor MeetingStore {

    public enum StoreError: Error, LocalizedError {
        case notFound(UUID)
        case importFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let id): "No meeting exists with id \(id)."
            case .importFailed(let detail): "The recording could not be imported. \(detail)"
            }
        }
    }

    public nonisolated let root: URL
    private let fileManager = FileManager.default

    /// - Parameter rootDirectory: overridden in tests; defaults to Application Support.
    public init(rootDirectory: URL? = nil) throws {
        if let rootDirectory {
            self.root = rootDirectory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.root = base
                .appending(path: "MeetingNotes", directoryHint: .isDirectory)
                .appending(path: "Meetings", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    public nonisolated func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public nonisolated func documentURL(for id: UUID) -> URL {
        directory(for: id).appending(path: "meeting.json", directoryHint: .notDirectory)
    }

    public nonisolated func audioURL(for meeting: Meeting) -> URL {
        directory(for: meeting.id).appending(path: meeting.audioFileName, directoryHint: .notDirectory)
    }

    // MARK: - Reading

    public func loadAll() throws -> [Meeting] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var meetings: [Meeting] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            // A meeting whose JSON is missing or corrupt is skipped rather than
            // failing the whole library load.
            if let meeting = try? load(id: id) { meetings.append(meeting) }
        }
        return meetings.sorted { $0.createdAt > $1.createdAt }
    }

    public func load(id: UUID) throws -> Meeting {
        let url = documentURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw StoreError.notFound(id) }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(Meeting.self, from: data)
    }

    // MARK: - Writing

    /// Writes `meeting.json` atomically. Called after every completed stage so a
    /// crash or a cancel never loses finished work.
    public func save(_ meeting: Meeting) throws {
        let directory = directory(for: meeting.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(meeting)
        try data.write(to: documentURL(for: meeting.id), options: .atomic)
    }

    public func delete(id: UUID) throws {
        let directory = directory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    // MARK: - Import

    /// Copies `sourceURL` into a new meeting directory and records its duration.
    public func importAudio(from sourceURL: URL, title: String? = nil) async throws -> Meeting {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw StoreError.importFailed("The file could not be read.")
        }

        let id = UUID()
        let directory = directory(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension.lowercased()
        let audioFileName = "audio.\(ext)"
        let destination = directory.appending(path: audioFileName, directoryHint: .notDirectory)

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw StoreError.importFailed(error.localizedDescription)
        }

        let duration: TimeInterval
        do {
            duration = try await AudioDecoder.probeDuration(url: destination)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        let meeting = Meeting(
            id: id,
            title: title ?? sourceURL.deletingPathExtension().lastPathComponent,
            duration: duration,
            audioFileName: audioFileName,
            originalFileName: sourceURL.lastPathComponent
        )
        try save(meeting)
        return meeting
    }

    // MARK: - Coding

    /// ISO 8601 with fractional seconds: readable when someone opens
    /// `meeting.json`, and precise enough that a save/load round-trip does not
    /// visibly shift a meeting's timestamp. `ISO8601FormatStyle` is a `Sendable`
    /// value type, unlike `ISO8601DateFormatter`.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
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
