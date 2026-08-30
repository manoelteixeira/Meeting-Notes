import Foundation

/// Seam between the pipeline and whichever ASR engine produces timed text.
///
/// The pipeline only ever sees `TimedTextRun`s, so an engine with finer
/// timestamps can be swapped in without touching merging or the UI.
public protocol TranscriptionService: Sendable {
    /// Locales this engine can transcribe.
    func supportedLocales() async -> [Locale]

    /// Ensures on-device models for `locale` are installed, reporting download
    /// progress in `0...1`. A no-op when the models are already present.
    func prepare(
        locale: Locale,
        onDownloadProgress: @Sendable @escaping (Double) -> Void
    ) async throws

    /// Transcribes `audioURL` into timed runs of text.
    /// - Parameter duration: total audio length, used to report progress.
    func transcribe(
        audioURL: URL,
        locale: Locale,
        duration: TimeInterval,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> [TimedTextRun]
}
