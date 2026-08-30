import Foundation

/// The ordered stages a meeting passes through. A meeting records the highest
/// stage it has completed so a retry resumes instead of restarting.
public enum ProcessingStage: Int, Codable, Sendable, CaseIterable, Comparable {
    case imported = 0
    case decoded = 1
    case transcribed = 2
    case diarized = 3
    case merged = 4
    case noted = 5

    public static func < (lhs: ProcessingStage, rhs: ProcessingStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .imported: "Imported"
        case .decoded: "Decoding audio"
        case .transcribed: "Transcribing"
        case .diarized: "Identifying speakers"
        case .merged: "Merging"
        case .noted: "Generating notes"
        }
    }
}

/// A progress event emitted by `ProcessingPipeline` while a meeting is running.
public struct PipelineProgress: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The stage is running with a known completion fraction in `0...1`.
        case running(Double)
        /// The stage is running but cannot report a fraction.
        case indeterminate
        /// A one-time model download is in flight for this stage.
        case downloadingModels(Double?)
        /// The stage finished.
        case finished
    }

    public var stage: ProcessingStage
    public var kind: Kind
    public var detail: String?

    public init(stage: ProcessingStage, kind: Kind, detail: String? = nil) {
        self.stage = stage
        self.kind = kind
        self.detail = detail
    }

    public var fraction: Double? {
        switch kind {
        case .running(let value): value
        case .downloadingModels(let value): value
        case .indeterminate: nil
        case .finished: 1
        }
    }
}

/// Persisted, coarse-grained state of a meeting. Live progress is not persisted;
/// it is held in memory by the app model while the pipeline runs.
public enum ProcessingStatus: Codable, Sendable, Equatable {
    /// Imported but never processed.
    case notStarted
    /// A pipeline task is currently running.
    case running
    /// Transcript is ready, but no notes model is installed to write the notes.
    case needsModel
    /// Every stage finished.
    case completed
    /// A stage failed. `code` drives retry affordances; `message` is user-facing.
    case failed(code: PipelineErrorCode, message: String)
    /// The user cancelled; the meeting keeps whatever stages already completed.
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .running: false
        default: true
        }
    }
}
