import Foundation
import Synchronization

@testable import MeetingNotesCore

/// Transcription that returns canned runs, so the pipeline can be tested without
/// models, audio, or the Neural Engine.
final class StubTranscriptionService: TranscriptionService, @unchecked Sendable {
    struct Calls: Sendable {
        var prepareCount = 0
        var transcribeCount = 0
        var lastLocale: String?
    }

    private let runs: [TimedTextRun]
    private let error: (any Error)?
    let calls = Mutex(Calls())

    init(runs: [TimedTextRun] = [], error: (any Error)? = nil) {
        self.runs = runs
        self.error = error
    }

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }

    func prepare(
        locale: Locale,
        onDownloadProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        calls.withLock { $0.prepareCount += 1 }
        onDownloadProgress(1)
    }

    func transcribe(
        audioURL: URL,
        locale: Locale,
        duration: TimeInterval,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> [TimedTextRun] {
        calls.withLock {
            $0.transcribeCount += 1
            $0.lastLocale = locale.identifier(.bcp47)
        }
        if let error { throw error }
        onProgress(0.5)
        onProgress(1)
        return runs
    }
}

/// Diarization that returns canned speaker spans and voiceprints.
final class StubDiarizationService: DiarizationService, @unchecked Sendable {
    private let segments: [DiarizedSegment]
    private let embeddings: [String: [Float]]
    private let error: (any Error)?
    let diarizeCount = Mutex(0)

    init(
        segments: [DiarizedSegment] = [],
        embeddings: [String: [Float]] = [:],
        error: (any Error)? = nil
    ) {
        self.segments = segments
        self.embeddings = embeddings
        self.error = error
    }

    var requiredSampleRate: Double { 16_000 }

    func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws {
        onDownloadProgress(1)
    }

    func diarize(
        samples: [Float],
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> DiarizationOutput {
        diarizeCount.withLock { $0 += 1 }
        if let error { throw error }
        onProgress(1)
        return DiarizationOutput(segments: segments, speakerEmbeddings: embeddings)
    }
}

/// Notes generation that returns canned markdown, so the pipeline can be tested
/// without downloading, loading, or running a language model. Keeping this the
/// only `NotesService` the suite ever constructs is what keeps it hermetic.
final class StubNotesService: NotesService, @unchecked Sendable {
    struct Calls: Sendable {
        var prepareCount = 0
        var generateCount = 0
        var lastSystem: String?
        var lastUser: String?
    }

    private let markdown: String
    private let error: (any Error)?
    private let ready: Bool
    private let truncated: Bool
    let calls = Mutex(Calls())

    init(
        markdown: String = "## Summary\n\nShort meeting.",
        ready: Bool = true,
        truncated: Bool = false,
        error: (any Error)? = nil
    ) {
        self.markdown = markdown
        self.ready = ready
        self.truncated = truncated
        self.error = error
    }

    var isReady: Bool { get async { ready } }

    func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws {
        calls.withLock { $0.prepareCount += 1 }
        if let error { throw error }
        onDownloadProgress(1)
    }

    func generate(
        system: String,
        user: String,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> NotesCompletion {
        calls.withLock {
            $0.generateCount += 1
            $0.lastSystem = system
            $0.lastUser = user
        }
        if let error { throw error }
        onDelta?(markdown)
        return NotesCompletion(text: markdown, isTruncated: truncated)
    }

    func unload() async {}
}
