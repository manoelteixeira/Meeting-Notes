import Foundation

/// Stable, persistable discriminator for pipeline failures. The UI keys retry
/// affordances off this rather than off a localized message.
public enum PipelineErrorCode: String, Codable, Sendable {
    case unsupportedAudio
    case unsupportedLocale
    case modelDownloadFailed
    case transcriptionFailed
    case diarizationFailed
    case notesModelNotInstalled
    case notesModelLoadFailed
    case notesTruncated
    case notesFailed
    case storageFailed
    case cancelled
}

public struct PipelineError: Error, Sendable, Equatable, LocalizedError {
    public var code: PipelineErrorCode
    public var message: String
    /// Stage that was running when the failure occurred.
    public var stage: ProcessingStage?
    /// Server-supplied `retry-after`, in seconds, when the failure carried one.
    public var retryAfter: TimeInterval?

    public init(
        code: PipelineErrorCode,
        message: String,
        stage: ProcessingStage? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.code = code
        self.message = message
        self.stage = stage
        self.retryAfter = retryAfter
    }

    public var errorDescription: String? { message }

    /// Whether retrying can start from the notes stage alone, leaving the
    /// transcript untouched.
    public var isNotesOnly: Bool {
        switch code {
        case .notesModelNotInstalled, .notesModelLoadFailed,
             .notesTruncated, .notesFailed:
            true
        default:
            false
        }
    }

    public static func unsupportedAudio(_ detail: String) -> PipelineError {
        PipelineError(
            code: .unsupportedAudio,
            message: "This audio file could not be read. \(detail)",
            stage: .decoded
        )
    }
}
