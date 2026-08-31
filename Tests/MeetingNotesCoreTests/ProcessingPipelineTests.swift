import Foundation
import Synchronization
import Testing

@testable import MeetingNotesCore

@Suite("Processing pipeline", .serialized)
struct ProcessingPipelineTests {

    // Two speakers alternating, so merging has something real to do.
    private let runs = [
        TimedTextRun(start: 0, end: 1.5, text: "Thanks for joining."),
        TimedTextRun(start: 2.0, end: 3.5, text: "Happy to be here."),
    ]
    private let segments = [
        DiarizedSegment(speakerID: "A", start: 0, end: 1.75),
        DiarizedSegment(speakerID: "B", start: 1.75, end: 4),
    ]

    /// Builds a store with one importable meeting backed by a real audio file,
    /// since the pipeline decodes before anything else.
    private func withFixture(
        _ body: (MeetingStore, Meeting) async throws -> Void
    ) async throws {
        let root = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Weekly.wav", directoryHint: .notDirectory)
        try AudioFixtures.writeSineWAV(to: source, seconds: 1.0)

        let store = try MeetingStore(
            rootDirectory: root.appending(path: "library", directoryHint: .isDirectory)
        )
        let meeting = try await store.importAudio(from: source)
        try await body(store, meeting)
    }

    private func makePipeline(
        store: MeetingStore,
        transcription: StubTranscriptionService,
        diarization: StubDiarizationService,
        notes: StubNotesService,
        directory: SpeakerDirectory? = nil,
        notesTemplate: NotesTemplate = .default
    ) -> ProcessingPipeline {
        ProcessingPipeline(
            store: store,
            transcription: transcription,
            diarization: diarization,
            directory: directory,
            notes: notes,
            notesTemplate: notesTemplate
        )
    }

    /// Stands in for "no model downloaded yet".
    private var noModel: StubNotesService { StubNotesService(ready: false) }

    // MARK: - Tests

    @Test("Without a notes model the transcript still completes, parked at needsModel")
    func stopsAtNeedsModel() async throws {
        try await withFixture { store, meeting in
            let transcription = StubTranscriptionService(runs: runs)
            let pipeline = makePipeline(
                store: store,
                transcription: transcription,
                diarization: StubDiarizationService(segments: segments),
                notes: noModel
            )

            let processed = try await pipeline.process(meeting)

            // The meeting is genuinely unfinished — saying "completed" here would
            // hide that the notes were never written.
            #expect(processed.status == .needsModel)
            #expect(processed.lastCompletedStage == .merged)
            #expect(processed.transcript.count == 2)
            #expect(processed.speakers.map(\.displayName) == ["Speaker 1", "Speaker 2"])
            #expect(processed.notesMarkdown == nil)

            // And it is on disk that way, not just in memory.
            let reloaded = try await store.load(id: meeting.id)
            #expect(reloaded.status == .needsModel)
            #expect(reloaded.transcript.count == 2)
        }
    }

    @Test("With a model installed the run finishes and stores the notes")
    func completesWithNotes() async throws {
        try await withFixture { store, meeting in
            let notes = StubNotesService(markdown: "## Summary\n\nShort meeting.")
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(runs: runs),
                diarization: StubDiarizationService(segments: segments),
                notes: notes
            )

            let processed = try await pipeline.process(
                meeting,
                options: ProcessingPipeline.Options(generateNotes: true, streamNotes: false)
            )

            #expect(processed.status == .completed)
            #expect(processed.lastCompletedStage == .noted)
            #expect(processed.notesMarkdown == "## Summary\n\nShort meeting.")
            // Not passing a template means the model saw the stock prompt.
            #expect(notes.calls.withLock { $0.lastSystem } == NotesPrompt.systemPrompt())
        }
    }

    @Test("A custom notes template reaches the model's system prompt")
    func customTemplateReachesModel() async throws {
        try await withFixture { store, meeting in
            let notes = StubNotesService(markdown: "## Overview\n\nShort meeting.")
            let template = NotesTemplate(
                sections: [
                    .init(title: "Overview", guidance: "one paragraph."),
                    .init(title: "Risks"),
                ],
                additionalInstructions: "Be terse."
            )
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(runs: runs),
                diarization: StubDiarizationService(segments: segments),
                notes: notes,
                notesTemplate: template
            )

            let processed = try await pipeline.process(
                meeting,
                options: ProcessingPipeline.Options(generateNotes: true, streamNotes: false)
            )
            #expect(processed.status == .completed)

            let system = try #require(notes.calls.withLock { $0.lastSystem })
            #expect(system.contains("## Overview\n## Risks"))
            #expect(system.contains("- Start your response with `## Overview`."))
            #expect(system.hasSuffix("Additional instructions:\nBe terse."))
        }
    }

    @Test("Retrying notes does not redo the transcript")
    func notesRetryResumes() async throws {
        try await withFixture { store, meeting in
            let transcription = StubTranscriptionService(runs: runs)
            let diarization = StubDiarizationService(segments: segments)

            // First pass: no model, so it stops after merging.
            var processed = try await makePipeline(
                store: store,
                transcription: transcription,
                diarization: diarization,
                notes: noModel
            ).process(meeting)
            #expect(transcription.calls.withLock { $0.transcribeCount } == 1)

            // Second pass with a model must reuse the transcript it already has.
            processed = try await makePipeline(
                store: store,
                transcription: transcription,
                diarization: diarization,
                notes: StubNotesService(markdown: "## Summary\n\nDone.")
            ).process(processed, options: .init(generateNotes: true, streamNotes: false))

            #expect(processed.status == .completed)
            #expect(processed.notesMarkdown == "## Summary\n\nDone.")
            #expect(transcription.calls.withLock { $0.transcribeCount } == 1)
            #expect(diarization.diarizeCount.withLock { $0 } == 1)
        }
    }

    @Test("forceReprocess redoes the transcript")
    func forceReprocessRerunsEverything() async throws {
        try await withFixture { store, meeting in
            let transcription = StubTranscriptionService(runs: runs)
            let diarization = StubDiarizationService(segments: segments)
            let pipeline = makePipeline(
                store: store,
                transcription: transcription,
                diarization: diarization,
                notes: noModel
            )

            let first = try await pipeline.process(meeting)
            _ = try await pipeline.process(first, options: .init(forceReprocess: true))

            #expect(transcription.calls.withLock { $0.transcribeCount } == 2)
            #expect(diarization.diarizeCount.withLock { $0 } == 2)
        }
    }

    @Test("A stage failure is recorded on the meeting with its code")
    func failureIsRecorded() async throws {
        try await withFixture { store, meeting in
            let failure = PipelineError(
                code: .transcriptionFailed,
                message: "no speech model",
                stage: .transcribed
            )
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(error: failure),
                diarization: StubDiarizationService(segments: segments),
                notes: noModel
            )

            await #expect(throws: PipelineError.self) {
                try await pipeline.process(meeting)
            }

            let reloaded = try await store.load(id: meeting.id)
            #expect(reloaded.status == .failed(code: .transcriptionFailed, message: "no speech model"))
            #expect(reloaded.transcript.isEmpty)
        }
    }

    @Test("An empty transcript is a failure rather than silently empty notes")
    func emptyTranscriptFails() async throws {
        try await withFixture { store, meeting in
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(runs: []),
                diarization: StubDiarizationService(segments: segments),
                notes: noModel
            )

            await #expect(throws: PipelineError.self) {
                try await pipeline.process(meeting)
            }
            let reloaded = try await store.load(id: meeting.id)
            #expect(reloaded.status == .failed(code: .transcriptionFailed, message: "No speech was recognized in this recording."))
        }
    }

    @Test("Cancelling leaves the meeting cancelled, not failed")
    func cancellation() async throws {
        try await withFixture { store, meeting in
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(error: CancellationError()),
                diarization: StubDiarizationService(segments: segments),
                notes: noModel
            )

            await #expect(throws: CancellationError.self) {
                try await pipeline.process(meeting)
            }
            let reloaded = try await store.load(id: meeting.id)
            #expect(reloaded.status == .cancelled)
        }
    }

    @Test("Every stage reports progress, ending in finished")
    func progressReporting() async throws {
        try await withFixture { store, meeting in
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(runs: runs),
                diarization: StubDiarizationService(segments: segments),
                notes: noModel
            )

            let events = Mutex<[PipelineProgress]>([])
            _ = try await pipeline.process(meeting) { event in
                events.withLock { $0.append(event) }
            }

            let recorded = events.withLock { $0 }
            let finished = Set(recorded.filter { $0.kind == .finished }.map(\.stage))
            #expect(finished == [.decoded, .transcribed, .diarized, .merged])
        }
    }

    // MARK: - Voice recognition

    // Long enough that both voices clear the recognizer's minimum-speech gate.
    private var longRuns: [TimedTextRun] {
        [
            TimedTextRun(start: 0, end: 15, text: "Thanks everyone for joining today."),
            TimedTextRun(start: 16, end: 31, text: "Happy to walk through the numbers."),
        ]
    }
    private var longSegments: [DiarizedSegment] {
        [
            DiarizedSegment(speakerID: "A", start: 0, end: 15.5),
            DiarizedSegment(speakerID: "B", start: 15.5, end: 31),
        ]
    }
    private let voiceA: [Float] = [1, 0]
    private let voiceB: [Float] = [0, 1]

    @Test("Recognition links speakers, promotes renames, and names later meetings")
    func recognitionAcrossMeetings() async throws {
        let root = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Weekly.wav", directoryHint: .notDirectory)
        try AudioFixtures.writeSineWAV(to: source, seconds: 1.0)
        let store = try MeetingStore(
            rootDirectory: root.appending(path: "library", directoryHint: .isDirectory)
        )
        let directory = try SpeakerDirectory(
            fileURL: root.appending(path: "people.json", directoryHint: .notDirectory)
        )
        let pipeline = makePipeline(
            store: store,
            transcription: StubTranscriptionService(runs: longRuns),
            diarization: StubDiarizationService(
                segments: longSegments,
                embeddings: ["A": voiceA, "B": voiceB]
            ),
            notes: noModel,
            directory: directory
        )

        // First meeting: both voices are new — linked, enrolled unnamed.
        var first = try await store.importAudio(from: source)
        first = try await pipeline.process(first)
        #expect(first.speakers.map(\.displayName) == ["Speaker 1", "Speaker 2"])
        #expect(first.speakers.allSatisfy { $0.personID != nil })
        #expect(await directory.people().count == 2)
        #expect(await directory.people().allSatisfy { $0.name == nil })

        // The user renames speaker A; reprocessing promotes that name onto the
        // still-unnamed person record.
        let personA = try #require(first.speaker(id: "A")?.personID)
        var renamed = first
        let indexA = try #require(renamed.speakers.firstIndex(where: { $0.id == "A" }))
        renamed.speakers[indexA].displayName = "Priya"
        try await store.save(renamed)
        let reprocessed = try await pipeline.process(
            renamed, options: .init(forceReprocess: true)
        )
        #expect(reprocessed.speaker(id: "A")?.displayName == "Priya")
        #expect(reprocessed.speaker(id: "A")?.personID == personA)
        #expect(await directory.people().first { $0.id == personA }?.name == "Priya")

        // Second meeting with the same voices: the name applies automatically,
        // and nobody is enrolled twice.
        var second = try await store.importAudio(from: source)
        second = try await pipeline.process(second)
        #expect(second.speaker(id: "A")?.displayName == "Priya")
        #expect(second.speaker(id: "A")?.personID == personA)
        #expect(second.speaker(id: "B")?.displayName == "Speaker 2")
        #expect(second.speaker(id: "B")?.personID != nil)
        #expect(await directory.people().count == 2)
    }

    @Test("Without a directory, speakers stay unlinked")
    func noDirectoryMeansNoLinks() async throws {
        try await withFixture { store, meeting in
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(runs: longRuns),
                diarization: StubDiarizationService(
                    segments: longSegments,
                    embeddings: ["A": voiceA, "B": voiceB]
                ),
                notes: noModel
            )

            let processed = try await pipeline.process(meeting)

            #expect(processed.speakers.allSatisfy { $0.personID == nil })
        }
    }

    @Test("Speakers heard only briefly are not enrolled")
    func briefSpeakersNotEnrolled() async throws {
        try await withFixture { store, meeting in
            let directory = try SpeakerDirectory(
                fileURL: store.root.appending(path: "people.json", directoryHint: .notDirectory)
            )
            // The default fixture speakers talk for ~1.5 s each — below the gate.
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(runs: runs),
                diarization: StubDiarizationService(
                    segments: segments,
                    embeddings: ["A": voiceA, "B": voiceB]
                ),
                notes: noModel,
                directory: directory
            )

            let processed = try await pipeline.process(meeting)

            #expect(processed.speakers.allSatisfy { $0.personID == nil })
            #expect(await directory.people().isEmpty)
        }
    }

    @Test("A directory that cannot be written never fails the run")
    func directoryFailureIsNonFatal() async throws {
        try await withFixture { store, meeting in
            // Points into a directory that does not exist, so persisting throws.
            let directory = try SpeakerDirectory(
                fileURL: store.root
                    .appending(path: "missing", directoryHint: .isDirectory)
                    .appending(path: "people.json", directoryHint: .notDirectory)
            )
            let pipeline = makePipeline(
                store: store,
                transcription: StubTranscriptionService(runs: longRuns),
                diarization: StubDiarizationService(
                    segments: longSegments,
                    embeddings: ["A": voiceA, "B": voiceB]
                ),
                notes: noModel,
                directory: directory
            )

            let processed = try await pipeline.process(meeting)

            #expect(processed.status == .needsModel)
            #expect(processed.lastCompletedStage == .merged)
            #expect(processed.speakers.allSatisfy { $0.personID == nil })
        }
    }

    @Test("The meeting's own locale is used, not the system one")
    func localeIsHonoured() async throws {
        try await withFixture { store, meeting in
            var meeting = meeting
            meeting.localeIdentifier = "de-DE"
            try await store.save(meeting)

            let transcription = StubTranscriptionService(runs: runs)
            _ = try? await makePipeline(
                store: store,
                transcription: transcription,
                diarization: StubDiarizationService(segments: segments),
                notes: noModel
            ).process(meeting)

            #expect(transcription.calls.withLock { $0.lastLocale } == "de-DE")
        }
    }
}
