import Foundation
import HuggingFace

/// Wraps the Hugging Face cache so the rest of the app deals in `NotesModel`
/// values and availability states instead of repo IDs and commit hashes.
///
/// Deliberately parallel to `SpeechModelManager`: both answer "is it here?",
/// "fetch it", and "how far along is the download?" for one of the three model
/// sets the app depends on.
///
/// Weights live in the shared Hugging Face cache — `HF_HUB_CACHE`, else
/// `HF_HOME/hub`, else `~/.cache/huggingface/hub` — so a model already pulled
/// by another MLX or Python tool is reused rather than downloaded twice.
public enum NotesModelManager {

    /// Every model in the catalog is a Hub *model* repo, never a dataset or space.
    private static let kind: Repo.Kind = .model

    private static var cache: HubCache { .default }

    static func repoID(_ model: NotesModel) -> Repo.ID? {
        Repo.ID(rawValue: model.repoID)
    }

    // MARK: - Local state

    /// Directory holding every snapshot of this model, or `nil` for an
    /// unparseable repo ID.
    public static func cacheDirectory(_ model: NotesModel) -> URL? {
        guard let repo = repoID(model) else { return nil }
        return cache.repoDirectory(repo: repo, kind: kind)
    }

    /// Commit hash of the downloaded snapshot, or `nil` if nothing is cached.
    public static func localRevision(_ model: NotesModel) -> String? {
        guard let repo = repoID(model) else { return nil }
        return cache.resolveRevision(repo: repo, kind: kind, ref: "main")
    }

    /// A ref file alone is not proof: an interrupted download can leave one
    /// behind with no weights under it, so the snapshot directory is checked too.
    public static func isInstalled(_ model: NotesModel) -> Bool {
        guard let repo = repoID(model), let revision = localRevision(model) else { return false }
        let snapshot = cache.snapshotsDirectory(repo: repo, kind: kind)
            .appendingPathComponent(revision)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: snapshot.path)
        return !(contents ?? []).isEmpty
    }

    /// Bytes currently on disk for this model. Walks the repo directory, so it
    /// reflects what a Remove would actually free.
    public static func installedSize(_ model: NotesModel) -> Int64 {
        guard let directory = cacheDirectory(model),
              let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey]
              )
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.fileAllocatedSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true, let size = values?.fileAllocatedSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Availability

    /// Local-only check. Never touches the network, so it is safe to call on
    /// every view update.
    public static func availability(for model: NotesModel) -> NotesModelAvailability {
        isInstalled(model) ? .installed : .notDownloaded
    }

    /// Asks the Hub whether `main` has moved since the local snapshot was taken.
    ///
    /// Returns `.installed` unchanged when the model is current, offline, or the
    /// lookup fails — a failed update check is not a reason to nag someone with
    /// a working model.
    public static func availabilityCheckingRemote(
        for model: NotesModel
    ) async -> NotesModelAvailability {
        guard isInstalled(model) else { return .notDownloaded }
        guard let remote = try? await remoteRevision(model), let local = localRevision(model) else {
            return .installed
        }
        return remote == local ? .installed : .updateAvailable
    }

    /// Commit hash `main` currently points at on the Hub.
    static func remoteRevision(_ model: NotesModel) async throws -> String? {
        guard let repo = repoID(model) else { return nil }
        let refs = try await HubClient().modelRefs(repo)
        return refs.branches.first { $0.name == "main" }?.targetOid
    }

    // MARK: - Mutation

    /// Deletes every snapshot of this model. The next run re-downloads.
    public static func remove(_ model: NotesModel) throws {
        guard let directory = cacheDirectory(model),
              FileManager.default.fileExists(atPath: directory.path)
        else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
