import Foundation

/// One entry in the curated catalog of models that can write notes.
///
/// The catalog is deliberately small and hardcoded: every entry has been checked
/// against the sectioned format `NotesPrompt` composes from the notes template,
/// which is a contract `MarkdownExporter` and the Notes tab both depend on. An
/// arbitrary repo ID would not carry that guarantee.
public struct NotesModel: Sendable, Equatable, Identifiable, Codable {
    /// Stable identifier persisted in `UserDefaults`; not the repo ID, so a
    /// repo can be repointed without invalidating the user's choice.
    public let id: String
    public let displayName: String
    /// Hugging Face repository, e.g. `mlx-community/Qwen3-4B-4bit`.
    public let repoID: String
    /// Approximate on-disk size, for the Settings row. Not enforced.
    public let approximateBytes: Int64
    /// Tokens the model can attend to, prompt plus generation.
    public let contextWindow: Int

    public init(
        id: String,
        displayName: String,
        repoID: String,
        approximateBytes: Int64,
        contextWindow: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.repoID = repoID
        self.approximateBytes = approximateBytes
        self.contextWindow = contextWindow
    }

    /// e.g. "2.3 GB", for the Settings row.
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: approximateBytes)
    }
}

/// The models the app offers. Three sizes, so the speed/quality trade can be
/// made per Mac rather than picked once for everyone.
public enum NotesModelCatalog {

    public static let qwen3_1_7B = NotesModel(
        id: "qwen3-1.7b-4bit",
        displayName: "Qwen3 1.7B",
        repoID: "mlx-community/Qwen3-1.7B-4bit",
        approximateBytes: 1_000_000_000,
        contextWindow: 32_768
    )

    public static let qwen3_4B = NotesModel(
        id: "qwen3-4b-4bit",
        displayName: "Qwen3 4B",
        repoID: "mlx-community/Qwen3-4B-4bit",
        approximateBytes: 2_300_000_000,
        contextWindow: 32_768
    )

    public static let qwen3_8B = NotesModel(
        id: "qwen3-8b-4bit",
        displayName: "Qwen3 8B",
        repoID: "mlx-community/Qwen3-8B-4bit",
        approximateBytes: 4_500_000_000,
        contextWindow: 32_768
    )

    /// Ordered smallest to largest, which is the order Settings lists them in.
    public static let all: [NotesModel] = [qwen3_1_7B, qwen3_4B, qwen3_8B]

    /// The middle size: usable notes without a 4.5 GB download.
    public static let `default` = qwen3_4B

    public static func model(id: String?) -> NotesModel {
        guard let id, let match = all.first(where: { $0.id == id }) else { return `default` }
        return match
    }
}

/// Installation state of a notes model, parallel to `SpeechModelAvailability`.
public enum NotesModelAvailability: Sendable, Equatable {
    case notDownloaded
    case downloading
    case installed
    /// Installed, but the repository's `main` has moved since it was fetched.
    case updateAvailable

    public var label: String {
        switch self {
        case .notDownloaded: "Not downloaded"
        case .downloading: "Downloading…"
        case .installed: "Ready"
        case .updateAvailable: "Update available"
        }
    }

    public var isInstalled: Bool {
        self == .installed || self == .updateAvailable
    }
}
