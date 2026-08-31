import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Speaker directory")
struct SpeakerDirectoryTests {

    private func withTemporaryFile(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root.appending(path: "people.json", directoryHint: .notDirectory))
    }

    @Test("People survive a round-trip through a second instance on the same file")
    func roundTrip() async throws {
        try await withTemporaryFile { url in
            let directory = try SpeakerDirectory(fileURL: url)
            _ = try await directory.recognize(
                embeddings: ["S1": [1, 0]],
                speakingTime: ["S1": 60],
                meetingDate: Date(timeIntervalSince1970: 300)
            )
            let enrolled = try #require(await directory.people().first)
            try await directory.rename(id: enrolled.id, to: "Priya")

            let reopened = try SpeakerDirectory(fileURL: url)
            let people = await reopened.people()
            #expect(people.count == 1)
            #expect(people[0].name == "Priya")
            #expect(people[0].embedding == [1, 0])
        }
    }

    @Test("A missing file is an empty directory, not an error")
    func missingFile() async throws {
        try await withTemporaryFile { url in
            let directory = try SpeakerDirectory(fileURL: url)
            #expect(await directory.people().isEmpty)
        }
    }

    @Test("A corrupt file is set aside as .bak and the directory starts empty")
    func corruptFile() async throws {
        try await withTemporaryFile { url in
            try Data("not json".utf8).write(to: url)

            let directory = try SpeakerDirectory(fileURL: url)
            #expect(await directory.people().isEmpty)

            let backup = url.deletingPathExtension().appendingPathExtension("json.bak")
            #expect(FileManager.default.fileExists(atPath: backup.path))
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Renaming an unknown id is a no-op")
    func renameMissingID() async throws {
        try await withTemporaryFile { url in
            let directory = try SpeakerDirectory(fileURL: url)
            try await directory.rename(id: UUID(), to: "Ghost")
            #expect(await directory.people().isEmpty)
        }
    }

    @Test("Delete removes one person; deleteAll empties the file")
    func deletion() async throws {
        try await withTemporaryFile { url in
            let directory = try SpeakerDirectory(fileURL: url)
            _ = try await directory.recognize(
                embeddings: ["S1": [1, 0], "S2": [0, 1]],
                speakingTime: ["S1": 60, "S2": 60],
                meetingDate: Date()
            )
            let people = await directory.people()
            #expect(people.count == 2)

            try await directory.delete(id: people[0].id)
            #expect(await directory.people().count == 1)

            try await directory.deleteAll()
            #expect(await directory.people().isEmpty)

            let reopened = try SpeakerDirectory(fileURL: url)
            #expect(await reopened.people().isEmpty)
        }
    }

    @Test("Recognize matches against what an earlier meeting enrolled")
    func recognizeAcrossMeetings() async throws {
        try await withTemporaryFile { url in
            let directory = try SpeakerDirectory(fileURL: url)
            let first = try await directory.recognize(
                embeddings: ["S1": [1, 0]],
                speakingTime: ["S1": 60],
                meetingDate: Date(timeIntervalSince1970: 100)
            )
            #expect(first.count == 1)
            #expect(first[0].isNewPerson)
            try await directory.rename(id: first[0].personID, to: "Priya")

            // Same voice, new run label, later meeting.
            let second = try await directory.recognize(
                embeddings: ["S7": [1, 0.01]],
                speakingTime: ["S7": 60],
                meetingDate: Date(timeIntervalSince1970: 500)
            )
            #expect(second == [
                .init(
                    runSpeakerID: "S7",
                    personID: first[0].personID,
                    personName: "Priya",
                    isNewPerson: false
                )
            ])
            let people = await directory.people()
            #expect(people.count == 1)
            #expect(people[0].lastHeardAt == Date(timeIntervalSince1970: 500))
        }
    }
}
