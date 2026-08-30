@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// On-device transcription via `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26).
///
/// Audio never leaves the machine. The file is decoded, converted to the format
/// the analyzer prefers, and streamed in through a bounded channel while results
/// are consumed concurrently.
public struct AppleSpeechTranscriptionService: TranscriptionService {

    /// Converted buffers allowed to queue ahead of the analyzer.
    private let channelCapacity: Int

    public init(channelCapacity: Int = 8) {
        self.channelCapacity = channelCapacity
    }

    public func supportedLocales() async -> [Locale] {
        await SpeechModelManager.supportedLocales()
    }

    public func prepare(
        locale: Locale,
        onDownloadProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        try await SpeechModelManager.ensureModel(for: locale, onProgress: onDownloadProgress)
    }

    public func transcribe(
        audioURL: URL,
        locale: Locale,
        duration: TimeInterval,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> [TimedTextRun] {
        let resolved = try await SpeechModelManager.resolveLocale(locale)
        let transcriber = SpeechModelManager.makeTranscriber(locale: resolved)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        )

        let buffer = AudioInputBuffer(capacity: channelCapacity)
        let channel = AudioInputChannel(buffer: buffer)

        // Collect results while audio is still being fed in.
        let collector = Task { () throws -> [TimedTextRun] in
            var runs: [TimedTextRun] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let newRuns = Self.timedRuns(from: result.text, fallbackRange: result.range)
                runs.append(contentsOf: newRuns)
                if duration > 0, let last = newRuns.last ?? runs.last {
                    onProgress(min(max(last.end / duration, 0), 1))
                }
            }
            return runs
        }

        let feeder = Task {
            do {
                try await Self.feedAudio(url: audioURL, analyzerFormat: analyzerFormat, into: buffer)
                await buffer.finish()
            } catch {
                await buffer.finish()
                throw error
            }
        }

        do {
            _ = try await analyzer.analyzeSequence(channel)
            try await feeder.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            feeder.cancel()
            collector.cancel()
            await buffer.finish()
            await analyzer.cancelAndFinishNow()
            if error is CancellationError { throw CancellationError() }
            throw Self.transcriptionError(error)
        }

        do {
            let runs = try await collector.value
            onProgress(1)
            return runs.sorted { $0.start < $1.start }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.transcriptionError(error)
        }
    }

    // MARK: - Result decoding

    /// Walks the attributed result, turning every run that carries an
    /// `audioTimeRange` into a `TimedTextRun`.
    ///
    /// If the engine returned no timestamps at all, the result's own range is
    /// used so the text is still usable (merging then falls back to whole-result
    /// speaker attribution).
    static func timedRuns(
        from text: AttributedString,
        fallbackRange: CMTimeRange
    ) -> [TimedTextRun] {
        var runs: [TimedTextRun] = []
        for run in text.runs {
            let fragment = String(text[run.range].characters)
            guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let timeRange = run.audioTimeRange else { continue }
            let start = CMTimeGetSeconds(timeRange.start)
            let end = CMTimeGetSeconds(timeRange.end)
            guard start.isFinite, end.isFinite, end >= start else { continue }
            runs.append(TimedTextRun(start: start, end: end, text: fragment))
        }

        if runs.isEmpty {
            let whole = String(text.characters)
            guard !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let start = CMTimeGetSeconds(fallbackRange.start)
            let end = CMTimeGetSeconds(fallbackRange.end)
            guard start.isFinite, end.isFinite else { return [] }
            return [TimedTextRun(start: start, end: max(start, end), text: whole)]
        }
        return runs
    }

    // MARK: - Audio feeding

    /// Reads `url` in chunks, converting to `analyzerFormat`, and pushes each
    /// converted buffer into `buffer`, which supplies backpressure.
    private static func feedAudio(
        url: URL,
        analyzerFormat: AVAudioFormat?,
        into buffer: AudioInputBuffer
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let outputFormat = analyzerFormat ?? inputFormat

        var converter: AVAudioConverter?
        if outputFormat != inputFormat {
            guard let made = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw PipelineError(
                    code: .transcriptionFailed,
                    message: "This audio could not be converted to the format the "
                        + "speech recognizer requires.",
                    stage: .transcribed
                )
            }
            converter = made
        }

        let inputChunk: AVAudioFrameCount = 8_192
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        var buffersFed = 0

        while true {
            if Task.isCancelled { throw CancellationError() }
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: inputChunk
            ) else { break }

            do {
                try file.read(into: inputBuffer, frameCount: inputChunk)
            } catch {
                // For several compressed formats `read` signals the end of the
                // file by throwing rather than by returning zero frames. Only
                // treat that as a real failure if we never read anything.
                if buffersFed > 0 { break }
                throw error
            }
            if inputBuffer.frameLength == 0 { break }

            let payload: AVAudioPCMBuffer
            if let converter {
                let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1_024
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: capacity
                ) else { break }

                nonisolated(unsafe) var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }
                if status == .error {
                    throw conversionError ?? PipelineError(
                        code: .transcriptionFailed,
                        message: "Audio conversion failed while transcribing.",
                        stage: .transcribed
                    )
                }
                guard outputBuffer.frameLength > 0 else { continue }
                payload = outputBuffer
            } else {
                payload = inputBuffer
            }

            await buffer.send(AnalyzerInput(buffer: payload))
            buffersFed += 1
        }
    }

    private static func transcriptionError(_ error: Error) -> Error {
        if let pipelineError = error as? PipelineError { return pipelineError }
        // Speech often surfaces bridged NSErrors whose localizedDescription is
        // just "The operation couldn't be completed", so include the domain and
        // code — without them these failures are undiagnosable.
        let nsError = error as NSError
        var detail = error.localizedDescription
        if detail.isEmpty || detail.contains("couldn\u{2019}t be completed") {
            detail = "\(nsError.domain) \(nsError.code)"
        }
        if let reason = nsError.localizedFailureReason {
            detail += " — \(reason)"
        }
        return PipelineError(
            code: .transcriptionFailed,
            message: "Transcription failed: \(detail)",
            stage: .transcribed
        )
    }
}
