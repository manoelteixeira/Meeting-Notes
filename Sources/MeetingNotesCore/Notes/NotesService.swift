import Foundation

/// Outcome of one generation, including whether it ran to a natural stop.
public struct NotesCompletion: Sendable, Equatable {
    public var text: String
    /// Generation hit the token cap, so the notes are cut off mid-thought.
    public var isTruncated: Bool

    public init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }
}

/// Seam between the pipeline and whichever language model writes the notes.
///
/// Shaped like `TranscriptionService` and `DiarizationService` so the pipeline
/// treats all three engines the same way: prepare (which may download), then
/// run. Keeping it a protocol is also what lets the test suite stay hermetic —
/// nothing in `Tests/` ever constructs the real MLX-backed implementation.
public protocol NotesService: Sendable {
    /// Whether the model is already on disk and ready to run. Checked by the
    /// pipeline so a run never kicks off a multi-gigabyte download on its own.
    var isReady: Bool { get async }

    /// Downloads and loads the model if this is the first run.
    func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws

    /// - Parameter onDelta: called with incremental text as it is generated;
    ///   pass `nil` to accumulate silently and return only the final text.
    func generate(
        system: String,
        user: String,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> NotesCompletion

    /// Releases the loaded model. The next `generate` reloads from disk, so
    /// this frees several gigabytes of resident memory without losing the
    /// download.
    func unload() async
}
