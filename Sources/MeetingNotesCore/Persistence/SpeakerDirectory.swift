import Foundation

/// On-disk directory of people known by voice, shared by all meetings.
///
/// A single JSON file next to the meetings library:
///
/// ```
/// ~/Library/Application Support/MeetingNotes/people.json
/// ```
///
/// Voiceprints are derived data — recomputable from the recordings — so a
/// corrupt file is set aside and the directory starts empty rather than ever
/// failing app launch; meetings keep their speaker names either way.
public actor SpeakerDirectory {

    private let fileURL: URL
    private var roster: [Person]

    /// - Parameter fileURL: overridden in tests; defaults to Application Support.
    public init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base.appending(path: "MeetingNotes", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appending(path: "people.json", directoryHint: .notDirectory)
        }
        self.roster = Self.load(from: self.fileURL)
    }

    // MARK: - Reading

    public func people() -> [Person] { roster }

    // MARK: - Mutations

    /// Renames a person; unknown ids are a no-op so a rename racing a delete
    /// cannot resurrect anyone.
    public func rename(id: UUID, to name: String?) throws {
        guard let index = roster.firstIndex(where: { $0.id == id }) else { return }
        roster[index].name = name
        try persist()
    }

    public func delete(id: UUID) throws {
        roster.removeAll { $0.id == id }
        try persist()
    }

    public func deleteAll() throws {
        roster = []
        try persist()
    }

    // MARK: - Recognition

    /// Matches one meeting's voiceprints against the roster, enrolls the new
    /// voices, persists, and returns who was who. The whole read-match-write
    /// cycle runs inside the actor so two meetings processing concurrently
    /// cannot both enroll the same unheard voice.
    public func recognize(
        embeddings: [String: [Float]],
        speakingTime: [String: TimeInterval],
        meetingDate: Date,
        config: SpeakerRecognizer.Config = SpeakerRecognizer.Config()
    ) throws -> [SpeakerRecognizer.Assignment] {
        let outcome = SpeakerRecognizer.recognize(
            embeddings: embeddings,
            speakingTime: speakingTime,
            people: roster,
            meetingDate: meetingDate,
            config: config
        )
        roster = outcome.people
        try persist()
        return outcome.assignments
    }

    // MARK: - Storage

    private static func load(from url: URL) -> [Person] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try StoreCoding.decoder.decode([Person].self, from: data)
        } catch {
            // Derived data: set the unreadable file aside and start over.
            let backup = url.deletingPathExtension().appendingPathExtension("json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    private func persist() throws {
        let data = try StoreCoding.encoder.encode(roster)
        try data.write(to: fileURL, options: .atomic)
    }
}
