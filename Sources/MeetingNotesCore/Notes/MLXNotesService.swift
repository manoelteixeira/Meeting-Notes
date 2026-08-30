import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Notes generation by a quantized LLM running on this Mac via MLX.
///
/// Weights are fetched from Hugging Face once and cached on disk afterwards, so
/// nothing but that initial download ever touches the network — the transcript
/// itself never leaves the machine.
///
/// An `actor` rather than a struct: it owns a loaded `ModelContainer` worth
/// several gigabytes, and both the load and the release need serializing.
public actor MLXNotesService: NotesService {

    private let model: NotesModel
    private let maxTokens: Int
    /// Low but not zero: the notes format is rigid, and sampling freely off it
    /// is how small models start inventing headings.
    private let temperature: Float

    private var container: ModelContainer?
    /// In flight load, so concurrent callers share one download rather than
    /// racing two.
    private var loadTask: Task<ModelContainer, Error>?

    public init(
        model: NotesModel = NotesModelCatalog.default,
        maxTokens: Int = 4_096,
        temperature: Float = 0.3
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    public var isReady: Bool {
        NotesModelManager.isInstalled(model)
    }

    // MARK: - Loading

    public func prepare(onDownloadProgress: @Sendable @escaping (Double) -> Void) async throws {
        _ = try await loadContainer(onDownloadProgress: onDownloadProgress)
    }

    private func loadContainer(
        onDownloadProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer {
        if let container {
            onDownloadProgress(1)
            return container
        }
        if let loadTask {
            return try await loadTask.value
        }

        let repoID = model.repoID
        let task = Task {
            try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: repoID),
                progressHandler: { progress in
                    onDownloadProgress(min(max(progress.fractionCompleted, 0), 1))
                }
            )
        }
        loadTask = task

        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            onDownloadProgress(1)
            return loaded
        } catch is CancellationError {
            loadTask = nil
            throw CancellationError()
        } catch {
            // Allow a retry: the usual cause is being offline mid-download.
            loadTask = nil
            throw PipelineError(
                code: .notesModelLoadFailed,
                message: "The notes model “\(model.displayName)” could not be loaded. "
                    + "(\(error.localizedDescription))",
                stage: .noted
            )
        }
    }

    /// Drops the loaded model, freeing its resident memory. The download is
    /// kept, so the next `generate` reloads from disk rather than re-fetching.
    public func unload() {
        loadTask?.cancel()
        loadTask = nil
        container = nil
    }

    // MARK: - Generation

    public func generate(
        system: String,
        user: String,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> NotesCompletion {
        let container = try await loadContainer(onDownloadProgress: { _ in })
        try Task.checkCancellation()

        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature
            ),
            // Qwen3 is a hybrid reasoning model: left alone it opens with a
            // `<think>` block, which would land in the notes and push the
            // required `## Summary` off the front. The chat template reads this
            // flag and skips the block entirely.
            additionalContext: ["enable_thinking": false]
        )

        var text = ""
        var isTruncated = false
        do {
            // `streamDetails` rather than `streamResponse`: the trailing `.info`
            // event carries the stop reason, which is the only honest way to
            // know the notes were cut off at the token cap rather than finished.
            for try await item in session.streamDetails(to: user) {
                if let chunk = item.chunk {
                    text += chunk
                    onDelta?(chunk)
                }
                if let info = item.info, case .length = info.stopReason {
                    isTruncated = true
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PipelineError(
                code: .notesFailed,
                message: "The notes could not be generated: \(error.localizedDescription)",
                stage: .noted
            )
        }

        return NotesCompletion(text: Self.strippingReasoning(text), isTruncated: isTruncated)
    }

    /// Belt and braces for `enable_thinking: false`: a model whose template
    /// ignores the flag still emits a reasoning block, and everything up to the
    /// closing tag has to go or the notes will not start at `## Summary`.
    ///
    /// An unterminated block means generation was cut off inside the reasoning,
    /// leaving no notes at all — dropping it all is correct, and the empty
    /// result is what surfaces as a failure upstream.
    static func strippingReasoning(_ text: String) -> String {
        guard let close = text.range(of: "</think>", options: .backwards) else {
            guard text.contains("<think>") else { return text }
            return ""
        }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
