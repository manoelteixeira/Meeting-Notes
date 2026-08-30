import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Meeting store")
struct MeetingStoreTests {

    /// Each test gets its own root so nothing touches the real library.
    private func withStore(_ body: (MeetingStore, URL) async throws -> Void) async throws {
        let root = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(rootDirectory: root)
        try await body(store, root)
    }

    @Test("A saved meeting reloads identically")
    func saveAndLoad() async throws {
        try await withStore { store, _ in
            let meeting = Meeting(
                title: "Standup",
                // Serialization keeps millisecond precision, so pin the date to
                // a whole second and compare the documents exactly.
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 300,
                audioFileName: "audio.m4a",
                originalFileName: "standup.m4a",
                transcript: [TranscriptSegment(start: 0, end: 2, text: "Hi", speakerID: "A")],
                speakers: [Speaker(id: "A", displayName: "Priya", colorIndex: 1)]
            )
            try await store.save(meeting)

            #expect(try await store.load(id: meeting.id) == meeting)
        }
    }

    @Test("Meetings list newest first, and unreadable directories are skipped")
    func loadAllOrdersAndTolerates() async throws {
        try await withStore { store, root in
            let older = Meeting(
                title: "Older",
                createdAt: Date(timeIntervalSince1970: 1_000),
                audioFileName: "audio.m4a",
                originalFileName: "a.m4a"
            )
            let newer = Meeting(
                title: "Newer",
                createdAt: Date(timeIntervalSince1970: 2_000),
                audioFileName: "audio.m4a",
                originalFileName: "b.m4a"
            )
            try await store.save(older)
            try await store.save(newer)

            // A directory with corrupt JSON must not break the whole library.
            let broken = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: broken.appending(path: "meeting.json"))
            // So must a stray directory that is not a meeting at all.
            try FileManager.default.createDirectory(
                at: root.appending(path: "scratch", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )

            let all = try await store.loadAll()

            #expect(all.map(\.title) == ["Newer", "Older"])
        }
    }

    @Test("Deleting removes the meeting and its audio, and is idempotent")
    func delete() async throws {
        try await withStore { store, _ in
            let meeting = Meeting(title: "Gone", audioFileName: "audio.m4a", originalFileName: "g.m4a")
            try await store.save(meeting)
            let directory = await store.directory(for: meeting.id)
            #expect(FileManager.default.fileExists(atPath: directory.path))

            try await store.delete(id: meeting.id)
            #expect(!FileManager.default.fileExists(atPath: directory.path))

            // Deleting again is not an error.
            try await store.delete(id: meeting.id)
        }
    }

    @Test("Loading a meeting that does not exist throws notFound")
    func missingMeeting() async throws {
        try await withStore { store, _ in
            await #expect(throws: MeetingStore.StoreError.self) {
                try await store.load(id: UUID())
            }
        }
    }

    @Test("Importing copies the audio alongside the document and records its duration")
    func importCopiesAudio() async throws {
        try await withStore { store, _ in
            let source = try AudioFixtures.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: source) }
            let audioURL = source.appending(path: "Weekly Sync.wav", directoryHint: .notDirectory)
            try AudioFixtures.writeSineWAV(to: audioURL, seconds: 1.5)

            let meeting = try await store.importAudio(from: audioURL)

            #expect(meeting.title == "Weekly Sync")
            #expect(meeting.originalFileName == "Weekly Sync.wav")
            #expect(meeting.audioFileName == "audio.wav")
            #expect(abs(meeting.duration - 1.5) < 0.05)
            #expect(meeting.status == .notStarted)
            #expect(meeting.lastCompletedStage == .imported)

            // The copy is what the pipeline reads, so the original can go away.
            let copied = await store.audioURL(for: meeting)
            #expect(FileManager.default.fileExists(atPath: copied.path))
            try FileManager.default.removeItem(at: audioURL)
            #expect(FileManager.default.fileExists(atPath: copied.path))

            // And it is already in the library.
            #expect(try await store.loadAll().map(\.id) == [meeting.id])
        }
    }

    @Test("Importing a non-audio file fails without leaving a stray directory")
    func importRejectsNonAudio() async throws {
        try await withStore { store, root in
            let source = try AudioFixtures.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: source) }
            let bogus = source.appending(path: "notes.txt", directoryHint: .notDirectory)
            try Data("this is not audio".utf8).write(to: bogus)

            await #expect(throws: (any Error).self) {
                try await store.importAudio(from: bogus)
            }
            #expect(try await store.loadAll().isEmpty)

            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(leftovers.isEmpty)
        }
    }
}
