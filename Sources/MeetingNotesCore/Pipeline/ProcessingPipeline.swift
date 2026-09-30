import Foundation

/// Runs a meeting through decode → diarize → transcribe per speaker → notes.
///
/// Speakers are identified first, then each speaker's own audio (everyone
/// else muted, timeline intact) is transcribed on its own, so every word
/// arrives already attributed. That keeps short interjections from being
/// swallowed by whoever is talking around them.
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
    private let directory: SpeakerDirectory?

    public init(
        store: MeetingStore,
        transcription: any TranscriptionService = AppleSpeechTranscriptionService(),
        diarization: any DiarizationService = DiarizationEngine.default.makeService(withVoiceprints: false),
        directory: SpeakerDirectory? = nil,
        notes: any NotesService = MLXNotesService(),
        notesTemplate: NotesTemplate = .default
    ) {
        self.store = store
        self.transcription = transcription
        self.diarization = diarization
        self.directory = directory
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

        // 1. Decode to 16 kHz mono once; the diarizer reads it directly and
        //    the per-speaker tracks are cut from it.
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

        // 3. Who spoke when. A recording the diarizer hears nothing in is
        //    still transcribed once, as a single speaker.
        try Task.checkCancellation()
        onProgress(PipelineProgress(stage: .diarized, kind: .running(0)))
        let diarized = try await diarization.diarize(samples: decoded.samples) { fraction in
            onProgress(PipelineProgress(stage: .diarized, kind: .running(fraction)))
        }
        onProgress(PipelineProgress(stage: .diarized, kind: .finished))
        let duration = meeting.duration
        let segments = diarized.segments.isEmpty
            ? [DiarizedSegment(speakerID: "S1", start: 0, end: decoded.duration)]
            : diarized.segments

        // 4. One masked track per speaker, transcribed on its own. Words the
        //    recognizer finds in the silence between spans are hallucinations,
        //    and a word caught in the padding that belongs to someone else's
        //    turn is theirs; both are dropped here. Audio no speaker covers
        //    gets a pass of its own only if there is audibly something in it.
        let tracksDirectory = FileManager.default.temporaryDirectory
            .appending(path: "meeting-notes-tracks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tracksDirectory) }

        let speakerIDs = SpeakerTrackBuilder.speakerOrder(segments)
        let leftover = SpeakerTrackBuilder.leftoverTrack(
            segments: segments,
            samples: decoded.samples,
            sampleRate: decoded.sampleRate
        )
        let passes = speakerIDs.count + (leftover == nil ? 0 : 1)

        var runsBySpeaker: [(speakerID: String, runs: [TimedTextRun])] = []
        for (index, speakerID) in speakerIDs.enumerated() {
            let track = SpeakerTrackBuilder.track(for: speakerID, segments: segments)
            let runs = try await transcribe(
                track: track,
                from: decoded,
                in: tracksDirectory,
                locale: locale,
                duration: duration,
                pass: (index, passes),
                detail: "Transcribing Speaker \(index + 1) of \(speakerIDs.count)",
                onProgress: onProgress
            )
            let kept = runs.filter {
                SpeakerTrackBuilder.owns($0, speakerID: speakerID, spans: track.spans, segments: segments)
            }
            runsBySpeaker.append((speakerID, kept))
        }
        if let leftover {
            let runs = try await transcribe(
                track: leftover,
                from: decoded,
                in: tracksDirectory,
                locale: locale,
                duration: duration,
                pass: (speakerIDs.count, passes),
                detail: "Transcribing untagged speech",
                onProgress: onProgress
            )
            // Nothing overlaps these by construction: the nearest-speaker
            // rule and "Unknown speaker" fallback of the overlap merge apply.
            let attributed = TranscriptMerger.merge(
                runs: runs.filter { SpeakerTrackBuilder.overlaps($0, leftover.spans) },
                diarization: segments
            )
            for utterance in attributed.segments {
                runsBySpeaker.append((
                    utterance.speakerID,
                    [TimedTextRun(start: utterance.start, end: utterance.end, text: utterance.text)]
                ))
            }
        }
        onProgress(PipelineProgress(stage: .transcribed, kind: .finished))
        runsBySpeaker = SpeakerTrackBuilder.droppingBleed(runsBySpeaker, segments: segments)

        guard runsBySpeaker.contains(where: { !$0.runs.isEmpty }) else {
            throw PipelineError(
                code: .transcriptionFailed,
                message: "No speech was recognized in this recording.",
                stage: .transcribed
            )
        }

        // 5. Interleave the speakers' words by time.
        try Task.checkCancellation()
        onProgress(PipelineProgress(stage: .merged, kind: .indeterminate))
        let merged = TranscriptMerger.assemble(runsBySpeaker: runsBySpeaker)
        meeting.transcript = merged.segments
        meeting.speakers = Self.preservingRenames(merged.speakers, from: meeting.speakers)
        if let directory {
            await Self.applyRecognition(
                to: &meeting,
                embeddings: diarized.speakerEmbeddings,
                directory: directory
            )
        }
        meeting.lastCompletedStage = .merged
        onProgress(PipelineProgress(stage: .merged, kind: .finished))
        try await store.save(meeting)

        return meeting
    }

    /// Writes one track, transcribes it, and removes the file again so no
    /// more than one track is ever on disk, and none is ever held in memory.
    /// Progress spans `pass` of the total passes.
    private func transcribe(
        track: SpeakerTrackBuilder.Track,
        from audio: DecodedAudio,
        in directory: URL,
        locale: Locale,
        duration: TimeInterval,
        pass: (index: Int, count: Int),
        detail: String,
        onProgress: @escaping ProgressHandler
    ) async throws -> [TimedTextRun] {
        try Task.checkCancellation()
        let count = Double(pass.count)
        let index = Double(pass.index)
        onProgress(PipelineProgress(stage: .transcribed, kind: .running(index / count), detail: detail))

        let url = directory.appending(path: "\(track.speakerID).wav", directoryHint: .notDirectory)
        try AudioFileWriter.writeMonoWAV(track, from: audio, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        return try await transcription.transcribe(
            audioURL: url,
            locale: locale,
            duration: duration
        ) { fraction in
            onProgress(
                PipelineProgress(
                    stage: .transcribed,
                    kind: .running((index + fraction) / count),
                    detail: detail
                )
            )
        }
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

    /// Matches this meeting's voiceprints against the speaker directory and
    /// links each recognized speaker to their person record.
    ///
    /// Name precedence per speaker: a name stored in the directory wins (rename
    /// fan-out keeps the directory current, so on reprocess it already holds
    /// the user's latest choice); an unnamed person takes a rename this meeting
    /// already carries (so reprocessing a meeting where "Priya" was named
    /// enrolls her voice under that name); otherwise the default "Speaker N"
    /// stays, linked so a later rename anywhere propagates.
    ///
    /// Deliberately non-throwing: recognition failing must not fail an import
    /// whose transcript is complete — speakers simply stay unlinked, exactly as
    /// when recognition is off.
    static func applyRecognition(
        to meeting: inout Meeting,
        embeddings: [String: [Float]],
        directory: SpeakerDirectory
    ) async {
        let speakingTime = Dictionary(grouping: meeting.transcript, by: \.speakerID)
            .mapValues { segments in
                segments.reduce(0) { $0 + ($1.end - $1.start) }
            }
        guard let assignments = try? await directory.recognize(
            embeddings: embeddings,
            speakingTime: speakingTime,
            meetingDate: meeting.createdAt
        ) else { return }

        // The names the merger would have assigned; anything else on a speaker
        // is a rename the user made, mirroring `preservingRenames`.
        let defaults = Set(meeting.speakers.map { speaker in
            speaker.isUnknown ? speaker.displayName : "Speaker \(speaker.colorIndex)"
        })

        for assignment in assignments {
            guard let index = meeting.speakers.firstIndex(
                where: { $0.id == assignment.runSpeakerID }
            ) else { continue }
            meeting.speakers[index].personID = assignment.personID
            let current = meeting.speakers[index].displayName
            if let name = assignment.personName {
                meeting.speakers[index].displayName = name
            } else if !defaults.contains(current) {
                try? await directory.rename(id: assignment.personID, to: current)
            }
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
