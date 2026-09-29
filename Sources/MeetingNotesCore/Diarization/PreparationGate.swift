import Foundation

/// Runs model preparation exactly once, and lets a later call retry if it failed.
///
/// Shared by the diarization services: each wraps a non-`Sendable` model
/// holder whose one mutating step is loading, so that step is serialized here.
actor PreparationGate {
    private var task: Task<Void, Error>?

    func run(_ operation: @Sendable @escaping () async throws -> Void) async throws {
        if let existing = task {
            do {
                return try await existing.value
            } catch {
                // A previous attempt failed (usually offline). Several callers
                // may have been waiting on it; the first to resume starts the
                // retry and the rest join that retry rather than each loading
                // the models again on top of it.
                if task == existing {
                    task = nil
                } else if let retry = task {
                    return try await retry.value
                }
            }
        }
        let newTask = Task(operation: operation)
        task = newTask
        do {
            try await newTask.value
        } catch {
            if task == newTask { task = nil }
            throw error
        }
    }
}
