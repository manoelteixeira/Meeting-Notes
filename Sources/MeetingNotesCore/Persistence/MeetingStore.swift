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
/// ~/Library/Application Support/MeetingNotes/Meetings/.recordings/
///     <uuid>.caf                 # a recording in progress, or orphaned by a crash
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

    /// How `importAudio` takes ownership of the source file.
    public enum Transfer: Sendable {
        /// Leave the original where it is — the user's own file.
        case copy
        /// Take the file itself — a recording the app made, which has no other home.
        case move
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

    /// Where recordings are written while they are in progress. Hidden and not
    /// a UUID, so `loadAll` never mistakes it for a meeting; inside `root`, so
    /// adopting a finished recording is a same-volume rename, not a copy.
    public nonisolated var recordingsDirectory: URL {
        root.appending(path: ".recordings", directoryHint: .isDirectory)
    }

    /// A fresh file URL for a new recording, creating the directory if needed.
    public func makeRecordingURL() throws -> URL {
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        return recordingsDirectory.appending(
            path: "\(UUID().uuidString).caf", directoryHint: .notDirectory
        )
    }

    /// Recordings left behind by a crash or a force quit — anything still in
    /// the recordings directory when no recording is running. Oldest first.
    public func orphanedRecordings() -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "caf" }
            .sorted { created($0) < created($1) }
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

    /// Copies (or moves) `sourceURL` into a new meeting directory and records
    /// its duration. A moved file that fails to import is put back, so a
    /// recording is never lost to a failed probe.
    public func importAudio(
        from sourceURL: URL,
        title: String? = nil,
        transfer: Transfer = .copy
    ) async throws -> Meeting {
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
            switch transfer {
            case .copy: try fileManager.copyItem(at: sourceURL, to: destination)
            case .move: try fileManager.moveItem(at: sourceURL, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw StoreError.importFailed(error.localizedDescription)
        }

        let duration: TimeInterval
        do {
            duration = try await AudioDecoder.probeDuration(url: destination)
        } catch {
            if transfer == .move { try? fileManager.moveItem(at: destination, to: sourceURL) }
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

    private static let encoder = StoreCoding.encoder
    private static let decoder = StoreCoding.decoder
}
