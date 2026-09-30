import Foundation
import MeetingNotesCore

/// Headless driver for the same pipeline the app uses.
///
/// Exists so every stage can be exercised and inspected without launching a UI —
/// useful for verifying a change, and for checking a recording from a terminal.
@main
struct CLI {

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(2)
        }

        do {
            switch command {
            case "process":
                try await runProcess(Arguments(Array(arguments.dropFirst())))
            case "transcribe":
                try await runTranscribe(Arguments(Array(arguments.dropFirst())))
            case "diarize":
                try await runDiarize(Arguments(Array(arguments.dropFirst())))
            case "tracks":
                try await runTracks(Arguments(Array(arguments.dropFirst())))
            case "models":
                try await runModels(Arguments(Array(arguments.dropFirst())))
            case "-h", "--help", "help":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command '\(command)'.\n\n".utf8))
                printUsage()
                exit(2)
            }
        } catch is CancellationError {
            FileHandle.standardError.write(Data("Cancelled.\n".utf8))
            exit(130)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Commands

    private static func runProcess(_ arguments: Arguments) async throws {
        let audioURL = try arguments.requirePath()
        let locale = arguments.locale
        // `--notes` opts in; without an installed model the pipeline stops
        // after merging.
        let wantsNotes = arguments.flag("notes") && !arguments.flag("skip-notes")

        let (store, meeting) = try await makeScratchMeeting(for: audioURL, locale: locale)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No speaker directory here, so no voiceprint pass either.
        let pipeline = ProcessingPipeline(
            store: store,
            diarization: try engine(arguments).makeService(withVoiceprints: false),
            notes: MLXNotesService(model: notesModel(arguments)),
            notesTemplate: notesTemplate(arguments)
        )

        let reporter = ProgressReporter()
        let processed = try await pipeline.process(
            meeting,
            options: ProcessingPipeline.Options(
                generateNotes: wantsNotes,
                forceReprocess: true,
                streamNotes: false
            ),
            onProgress: { progress in reporter.report(progress) }
        )
        reporter.finish()

        print("")
        print(MarkdownExporter.export(processed))

        if wantsNotes, case .needsModel = processed.status {
            let model = notesModel(arguments)
            let hint = "\nThe notes model “\(model.displayName)” is not installed. Run "
                + "`meeting-notes-cli models --download-notes-model` first, then rerun "
                + "with --notes.\n"
            FileHandle.standardError.write(Data(hint.utf8))
        }

        if let output = arguments.value("output") {
            let url = URL(fileURLWithPath: output)
            try Data(MarkdownExporter.export(processed).utf8).write(to: url, options: .atomic)
            FileHandle.standardError.write(Data("Wrote \(url.path)\n".utf8))
        }
    }

    private static func runTranscribe(_ arguments: Arguments) async throws {
        let audioURL = try arguments.requirePath()
        let locale = arguments.locale
        let duration = try await AudioDecoder.probeDuration(url: audioURL)

        let service = AppleSpeechTranscriptionService()
        let reporter = ProgressReporter()
        try await service.prepare(locale: locale) { fraction in
            reporter.report(PipelineProgress(stage: .transcribed, kind: .downloadingModels(fraction)))
        }
        let runs = try await service.transcribe(
            audioURL: audioURL,
            locale: locale,
            duration: duration
        ) { fraction in
            reporter.report(PipelineProgress(stage: .transcribed, kind: .running(fraction)))
        }
        reporter.finish()

        print("")
        for run in runs {
            print("[\(MarkdownExporter.timestamp(run.start))–\(MarkdownExporter.timestamp(run.end))] \(run.text)")
        }
        FileHandle.standardError.write(Data("\n\(runs.count) timed runs.\n".utf8))
    }

    private static func runDiarize(_ arguments: Arguments) async throws {
        let audioURL = try arguments.requirePath()
        let decoded = try await AudioDecoder.decodeMono16k(url: audioURL)

        // Tuning overrides. Sortformer: `--min-on <s>`, `--min-off <s>`.
        // pyannote: `--cluster-threshold <x>`, `--num-speakers <n>`,
        // `--min-speakers <n>`, `--max-speakers <n>`, `--fa <x>`, `--fb <x>`.
        // `--voiceprints` adds the pyannote pass the app runs for recognition.
        let service: any DiarizationService
        switch try engine(arguments) {
        case .sortformer:
            let sortformer = SortformerDiarizationService(
                minDurationOn: arguments.value("min-on").flatMap(Float.init),
                minDurationOff: arguments.value("min-off").flatMap(Float.init)
            )
            service = arguments.flag("voiceprints")
                ? VoiceprintAugmentedDiarizationService(
                    primary: sortformer,
                    voiceprints: FluidAudioDiarizationService()
                )
                : sortformer
        case .pyannote:
            if arguments.flag("voiceprints") {
                FileHandle.standardError.write(
                    Data("--voiceprints is implied for pyannote, which produces its own.\n".utf8)
                )
            }
            service = FluidAudioDiarizationService(
                clusteringThreshold: arguments.value("cluster-threshold").flatMap(Double.init),
                numSpeakers: arguments.value("num-speakers").flatMap(Int.init),
                minSpeakers: arguments.value("min-speakers").flatMap(Int.init),
                maxSpeakers: arguments.value("max-speakers").flatMap(Int.init),
                Fa: arguments.value("fa").flatMap(Double.init),
                Fb: arguments.value("fb").flatMap(Double.init)
            )
        }
        let reporter = ProgressReporter()
        try await service.prepare { fraction in
            reporter.report(PipelineProgress(stage: .diarized, kind: .downloadingModels(fraction)))
        }
        let output = try await service.diarize(samples: decoded.samples) { fraction in
            reporter.report(PipelineProgress(stage: .diarized, kind: .running(fraction)))
        }
        reporter.finish()

        print("")
        for segment in output.segments {
            print(
                "\(MarkdownExporter.timestamp(segment.start))–"
                    + "\(MarkdownExporter.timestamp(segment.end))  \(segment.speakerID)"
            )
        }
        let speakers = Set(output.segments.map(\.speakerID)).count
        let voiceprints = output.speakerEmbeddings.keys.sorted().joined(separator: ", ")
        FileHandle.standardError.write(
            Data(
                ("\n\(output.segments.count) segments across \(speakers) speakers."
                    + (voiceprints.isEmpty ? "" : " Voiceprints for: \(voiceprints).") + "\n").utf8
            )
        )
    }

    /// Writes the per-speaker tracks the pipeline transcribes, for listening
    /// to or running `transcribe` on.
    private static func runTracks(_ arguments: Arguments) async throws {
        let audioURL = try arguments.requirePath()
        guard let output = arguments.value("output") else {
            throw PipelineError(code: .unsupportedAudio, message: "tracks needs --output <directory>.")
        }
        let directory = URL(fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoded = try await AudioDecoder.decodeMono16k(url: audioURL)
        let service = try engine(arguments).makeService(withVoiceprints: false)
        let reporter = ProgressReporter()
        let found = try await service.diarize(samples: decoded.samples) { fraction in
            reporter.report(PipelineProgress(stage: .diarized, kind: .running(fraction)))
        }.segments
        reporter.finish()
        // Same fallback as the pipeline: nothing found still means one track.
        let segments = found.isEmpty
            ? [DiarizedSegment(speakerID: "S1", start: 0, end: decoded.duration)]
            : found

        var tracks = SpeakerTrackBuilder.speakerOrder(segments).map { speakerID in
            SpeakerTrackBuilder.track(for: speakerID, segments: segments)
        }
        if let leftover = SpeakerTrackBuilder.leftoverTrack(
            segments: segments, samples: decoded.samples, sampleRate: decoded.sampleRate
        ) {
            tracks.append(leftover)
        }

        print("")
        for track in tracks {
            let url = directory.appending(path: "\(track.speakerID).wav", directoryHint: .notDirectory)
            try AudioFileWriter.writeMonoWAV(track, from: decoded, to: url)
            let spans = track.spans
                .map { "\(MarkdownExporter.timestamp($0.lowerBound))–\(MarkdownExporter.timestamp($0.upperBound))" }
                .joined(separator: ", ")
            print("\(url.lastPathComponent)  \(spans)")
        }
    }

    private static func runModels(_ arguments: Arguments) async throws {
        let locale = arguments.locale
        print("On-device speech transcription: \(SpeechModelManager.isAvailable ? "available" : "unavailable")")
        print("Locale \(locale.identifier(.bcp47)): \(await SpeechModelManager.availability(for: locale).label)")

        print("")
        print("Notes models:")
        for entry in NotesModelCatalog.all {
            let marker = entry.id == notesModel(arguments).id ? "*" : " "
            let status = NotesModelManager.availability(for: entry).label
            print("  \(marker) \(entry.displayName.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + "\(entry.formattedSize.padding(toLength: 9, withPad: " ", startingAt: 0))\(status)")
        }
        print("  (* is the model --notes-model selects; override with --notes-model <id>)")

        if arguments.flag("download-notes-model") {
            let entry = notesModel(arguments)
            let reporter = ProgressReporter()
            try await MLXNotesService(model: entry).prepare { fraction in
                reporter.report(
                    PipelineProgress(
                        stage: .noted,
                        kind: .downloadingModels(fraction),
                        detail: "Downloading \(entry.displayName)"
                    )
                )
            }
            reporter.finish()
            print("Notes model \(entry.displayName) ready.")
        }

        if arguments.flag("download") {
            let reporter = ProgressReporter()
            try await SpeechModelManager.ensureModel(for: locale) { fraction in
                reporter.report(PipelineProgress(stage: .transcribed, kind: .downloadingModels(fraction)))
            }
            try await engine(arguments).makeService(withVoiceprints: false).prepare { fraction in
                reporter.report(PipelineProgress(stage: .diarized, kind: .downloadingModels(fraction)))
            }
            reporter.finish()
            print("Models ready.")
        } else {
            let installed = await SpeechModelManager.installedLocales()
            print("Installed locales: \(installed.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", "))")
        }
    }

    // MARK: - Helpers

    /// `--engine sortformer|pyannote`, defaulting to the app's default. Unlike
    /// the model ids, a typo here would silently run the wrong model, so it fails.
    private static func engine(_ arguments: Arguments) throws -> DiarizationEngine {
        guard let raw = arguments.value("engine") else { return .default }
        guard let engine = DiarizationEngine(rawValue: raw) else {
            let known = DiarizationEngine.allCases.map(\.rawValue).joined(separator: ", ")
            throw PipelineError(
                code: .diarizationFailed,
                message: "Unknown speaker engine '\(raw)'. Choose one of: \(known)."
            )
        }
        return engine
    }

    /// `--notes-model <id>`, defaulting to the catalog's default. Unknown ids
    /// fall back rather than failing, matching how `--locale` behaves.
    private static func notesModel(_ arguments: Arguments) -> NotesModel {
        NotesModelCatalog.model(id: arguments.value("notes-model"))
    }

    /// `--notes-sections "A,B,C"` and `--notes-instructions "..."`, defaulting
    /// to the standard template. A title matching one of the default sections
    /// keeps that section's guidance, so `--notes-sections "Summary,Decisions"`
    /// still gets the standard rules for both; other titles get a heading and
    /// no rule. Absent or empty values fall back rather than failing.
    private static func notesTemplate(_ arguments: Arguments) -> NotesTemplate {
        var template = NotesTemplate.default
        if let list = arguments.value("notes-sections") {
            template.sections = list.split(separator: ",").map { rawTitle in
                let title = rawTitle.trimmingCharacters(in: .whitespaces)
                let canonical = NotesTemplate.default.sections.first {
                    $0.title.compare(title, options: .caseInsensitive) == .orderedSame
                }
                return canonical ?? .init(title: title)
            }
        }
        template.additionalInstructions = arguments.value("notes-instructions") ?? ""
        return template
    }

    /// Imports into a throwaway store so CLI runs never touch the app's library.
    private static func makeScratchMeeting(
        for audioURL: URL,
        locale: Locale
    ) async throws -> (MeetingStore, Meeting) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "meeting-notes-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try MeetingStore(rootDirectory: root)
        var meeting = try await store.importAudio(from: audioURL)
        meeting.localeIdentifier = locale.identifier(.bcp47)
        try await store.save(meeting)
        return (store, meeting)
    }

    private static func printUsage() {
        print(
            """
            meeting-notes-cli — headless driver for the Meeting Notes pipeline

            USAGE
              meeting-notes-cli process <audio-file> [--notes] [--notes-model <id>]
                                        [--notes-sections "<a,b,c>"]
                                        [--notes-instructions "<text>"]
                                        [--engine sortformer|pyannote]
                                        [--locale <bcp47>] [--output <file.md>]
              meeting-notes-cli transcribe <audio-file> [--locale <bcp47>]
              meeting-notes-cli diarize <audio-file> [--engine sortformer|pyannote]
                                        sortformer: [--min-on <s>] [--min-off <s>]
                                                    [--voiceprints]
                                        pyannote:   [--cluster-threshold <x>]
                                        [--num-speakers <n>] [--min-speakers <n>]
                                        [--max-speakers <n>] [--fa <x>] [--fb <x>]
              meeting-notes-cli tracks <audio-file> --output <directory>
                                       [--engine sortformer|pyannote]
              meeting-notes-cli models [--locale <bcp47>] [--download]
                                       [--engine sortformer|pyannote]
                                       [--download-notes-model] [--notes-model <id>]

            COMMANDS
              process     Decode, identify speakers, transcribe each speaker's own
                          audio and interleave, then print Markdown. Add --notes to
                          also write the notes with the local model.
              transcribe  Print the raw timed text runs from on-device speech recognition.
              diarize     Print the speaker segments found by local diarization.
              tracks      Write the per-speaker audio tracks the pipeline transcribes,
                          one WAV per speaker with everyone else muted.
              models      Show on-device model status; --download fetches the speech and
                          speaker models, --download-notes-model fetches the notes model.

            NOTES
              Everything runs on this Mac. Nothing but the one-time model downloads
              ever touches the network — no audio, and no transcript text.

              --notes-sections replaces the default section headings (Summary, Key
              Discussion Points, Decisions, Action Items) with a comma-separated
              list of your own; --notes-instructions adds free-form guidance such
              as a language or level of detail.
            """
        )
    }
}

/// Minimal flag parser: `--name value` and bare `--flag`.
struct Arguments {
    private let raw: [String]

    init(_ raw: [String]) { self.raw = raw }

    var positional: [String] { raw.filter { !$0.hasPrefix("--") } }

    func flag(_ name: String) -> Bool {
        raw.contains("--\(name)")
    }

    func value(_ name: String) -> String? {
        guard let index = raw.firstIndex(of: "--\(name)"), index + 1 < raw.count else { return nil }
        let next = raw[index + 1]
        return next.hasPrefix("--") ? nil : next
    }

    var locale: Locale {
        value("locale").map(Locale.init(identifier:)) ?? Locale.current
    }

    func requirePath() throws -> URL {
        guard let path = positional.first else {
            throw PipelineError(code: .unsupportedAudio, message: "No audio file was given.")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PipelineError(code: .unsupportedAudio, message: "No such file: \(url.path)")
        }
        return url
    }
}
