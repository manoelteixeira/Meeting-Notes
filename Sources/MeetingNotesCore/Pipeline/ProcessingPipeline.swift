import Foundation

/// Runs a meeting through decode → transcribe → diarize → merge → notes.
///
/// The meeting document is written after every completed stage, so cancelling or
/// crashing mid-run never costs finished work and a retry resumes from the last
/// good stage rather than starting over.
///
/// Cancellation is cooperative: the caller owns the `Task` and cancelling it
/// unwinds the pipeline, leaving the meeting at its last completed stage.
public struct ProcessingPipeline: Sendable {

    public struct Options: Sendable, Equatable {
        /// Run the notes stage. When false the pipeline stops after merging.
        public var generateNotes: Bool
        /// Ignore already-completed stages and redo everything.
        public var forceReprocess: Bool
        /// Stream notes so they appear as they are written.
        public var streamNotes: Bool

        public init(
            generateNotes: Bool = true,
            forceReprocess: Bool = false,
            streamNotes: Bool = true
        ) {
            self.generateNotes = generateNotes
            self.forceReprocess = forceReprocess
            self.streamNotes = streamNotes
        }

        public static let `default` = Options()
        /// Everything except the notes stage — used by the CLI and by imports
        /// made before a notes model is installed.
        public static let withoutNotes = Options(generateNotes: false)
    }

    public typealias ProgressHandler = @Sendable (PipelineProgress) -> Void
    public typealias NotesDeltaHandler = @Sendable (String) -> Void

    private let store: MeetingStore
    private let transcription: any TranscriptionService
    private let diarization: any DiarizationService
    private let notes: any NotesService
    private let notesTemplate: NotesTemplate

    public init(
        store: MeetingStore,
        transcription: any TranscriptionService = AppleSpeechTranscriptionService(),
        diarization: any DiarizationService = FluidAudioDiarizationService(),
        notes: any NotesService = MLXNotesService(),
        notesTemplate: NotesTemplate = .default
    ) {
        self.store = store
        self.transcription = transcription
        self.diarization = diarization
        self.notes = notes
        self.notesTemplate = notesTemplate
    }

    // MARK: - Entry point

    @discardableResult
    public func process(
        _ meeting: Meeting,
        options: Options = .default,
        onProgress: @escaping ProgressHandler = { _ in },
        onNotesDelta: NotesDeltaHandler? = nil
    ) async throws -> Meeting {
        var meeting = meeting
        meeting.status = .running
        try await store.save(meeting)

        do {
            // Everything up to and including merging is one unit: the transcript
            // and its speaker labels are produced together, so resuming part-way
            // through them is not meaningful.
            let needsTranscript = options.forceReprocess
                || meeting.lastCompletedStage < .merged
                || meeting.transcript.isEmpty

            if needsTranscript {
                meeting = try await runTranscriptStages(meeting, onProgress: onProgress)
            }

            if options.generateNotes {
                meeting = try await runNotesStage(
                    meeting,
                    options: options,
                    onProgress: onProgress,
                    onNotesDelta: onNotesDelta
                )
            } else {
                meeting.status = .completed
                try await store.save(meeting)
            }
            return meeting
        } catch is CancellationError {
            meeting.status = .cancelled
            try? await store.save(meeting)
            throw CancellationError()
        } catch {
            let failure = Self.pipelineError(from: error)
            meeting.status = .failed(code: failure.code, message: failure.message)
            try? await store.save(meeting)
            throw failure
        }
    }

    // MARK: - Transcript stages

    private func runTranscriptStages(
        _ input: Meeting,
        onProgress: @escaping ProgressHandler
    ) async throws -> Meeting {
        var meeting = input
        let audioURL = store.audioURL(for: meeting)
        let locale = Locale(identifier: meeting.localeIdentifier)

        // 1. Decode to 16 kHz mono for the diarizer. SpeechAnalyzer reads the
        //    original file itself, since it prefers its own best audio format.
        onProgress(PipelineProgress(stage: .decoded, kind: .indeterminate))
        let decoded = try await AudioDecoder.decodeMono16k(url: audioURL)
        if decoded.duration > 0, abs(decoded.duration - meeting.duration) > 0.5 {
            meeting.duration = decoded.duration
        }
        meeting.lastCompletedStage = .decoded
        onProgress(PipelineProgress(stage: .decoded, kind: .finished))
        try await store.save(meeting)

        // 2. Download any missing models first, so the two download progress
        //    bars do not overlap and compete for bandwidth.
        try Task.checkCancellation()
        try await transcription.prepare(locale: locale) { fraction in
            onProgress(
                PipelineProgress(
                    stage: .transcribed,
                    kind: .downloadingModels(fraction),
                    detail: "Downloading speech model"
                )
            )
        }
        try await diarization.prepare { fraction in
            onProgress(
                PipelineProgress(
                    stage: .diarized,
                    kind: .downloadingModels(fraction),
                    detail: "Downloading speaker models"
                )
            )
        }

        // 3. Transcription and diarization are independent reads of the same
        //    audio, so run them concurrently.
        try Task.checkCancellation()
        let duration = meeting.duration
        async let runsTask: [TimedTextRun] = transcription.transcribe(
            audioURL: audioURL,
            locale: locale,
            duration: duration
        ) { fraction in
            onProgress(PipelineProgress(stage: .transcribed, kind: .running(fraction)))
        }
        async let segmentsTask: [DiarizedSegment] = diarization.diarize(
            samples: decoded.samples
        ) { fraction in
            onProgress(PipelineProgress(stage: .diarized, kind: .running(fraction)))
        }

        let (runs, segments) = try await (runsTask, segmentsTask)
        onProgress(PipelineProgress(stage: .transcribed, kind: .finished))
        onProgress(PipelineProgress(stage: .diarized, kind: .finished))

        guard !runs.isEmpty else {
            throw PipelineError(
                code: .transcriptionFailed,
                message: "No speech was recognized in this recording.",
                stage: .transcribed
            )
        }

        // 4. Attribute text to speakers.
        try Task.checkCancellation()
        onProgress(PipelineProgress(stage: .merged, kind: .indeterminate))
        let merged = TranscriptMerger.merge(runs: runs, diarization: segments)
        meeting.transcript = merged.segments
        meeting.speakers = Self.preservingRenames(merged.speakers, from: meeting.speakers)
        meeting.lastCompletedStage = .merged
        onProgress(PipelineProgress(stage: .merged, kind: .finished))
        try await store.save(meeting)

        return meeting
    }

    /// Keeps user-chosen speaker names across a reprocess, matching on speaker id.
    static func preservingRenames(_ fresh: [Speaker], from existing: [Speaker]) -> [Speaker] {
        let defaults = Set(fresh.map(\.displayName))
        return fresh.map { speaker in
            guard let previous = existing.first(where: { $0.id == speaker.id }),
                  // Only carry over a name the user actually changed.
                  !defaults.contains(previous.displayName)
            else { return speaker }
            var renamed = speaker
            renamed.displayName = previous.displayName
            return renamed
        }
    }

    // MARK: - Notes stage

    private func runNotesStage(
        _ input: Meeting,
        options: Options,
        onProgress: @escaping ProgressHandler,
        onNotesDelta: NotesDeltaHandler?
    ) async throws -> Meeting {
        var meeting = input

        // Checked rather than downloaded: pulling gigabytes of weights is not
        // something to start behind someone's back mid-import. Settings owns
        // installing the model; this stage only runs one that is already here.
        guard await notes.isReady else {
            // Not a failure: the transcript is complete and useful on its own.
            meeting.status = .needsModel
            try await store.save(meeting)
            return meeting
        }

        try Task.checkCancellation()
        // Indeterminate covers both halves of this stage: loading several
        // gigabytes off disk, which reports nothing, and then generating, whose
        // only real progress signal is the text streaming out.
        onProgress(PipelineProgress(stage: .noted, kind: .indeterminate))

        let generator = NotesGenerator(service: notes, template: notesTemplate)
        let generated = try await generator.generate(
            for: meeting,
            onDelta: options.streamNotes ? (onNotesDelta ?? { _ in }) : nil
        )

        meeting.notesMarkdown = generated.markdown
        meeting.lastCompletedStage = .noted
        meeting.status = generated.isTruncated
            ? .failed(
                code: .notesTruncated,
                message: "The notes were cut off before they finished. Regenerate to try again."
            )
            : .completed
        onProgress(PipelineProgress(stage: .noted, kind: .finished))
        try await store.save(meeting)
        return meeting
    }

    // MARK: - Errors

    static func pipelineError(from error: Error) -> PipelineError {
        if let pipelineError = error as? PipelineError { return pipelineError }
        if let storeError = error as? MeetingStore.StoreError {
            return PipelineError(
                code: .storageFailed,
                message: storeError.localizedDescription
            )
        }
        return PipelineError(code: .notesFailed, message: error.localizedDescription)
    }
}
