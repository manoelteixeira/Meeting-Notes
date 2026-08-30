import Foundation
import Speech

/// Installation state of the on-device speech model for a locale.
public enum SpeechModelAvailability: Sendable, Equatable {
    case unsupported
    case supported
    case downloading
    case installed

    public var label: String {
        switch self {
        case .unsupported: "Not supported"
        case .supported: "Not downloaded"
        case .downloading: "Downloading…"
        case .installed: "Ready"
        }
    }
}

/// Wraps `AssetInventory` so the rest of the app deals in locales and progress
/// fractions instead of Speech asset requests.
public enum SpeechModelManager {

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// Maps a user-chosen locale onto the closest locale the transcriber supports
    /// (e.g. `en_GB` → `en-GB`, or a bare `en` → a regional variant).
    public static func resolveLocale(_ locale: Locale) async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return match
        }
        throw PipelineError(
            code: .unsupportedLocale,
            message: "On-device transcription is not available for \(displayName(locale)). "
                + "Choose a different language in Settings.",
            stage: .transcribed
        )
    }

    public static func availability(for locale: Locale) async -> SpeechModelAvailability {
        guard isAvailable else { return .unsupported }
        guard let resolved = try? await resolveLocale(locale) else { return .unsupported }
        let transcriber = makeTranscriber(locale: resolved)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .supported
        }
    }

    /// Downloads and installs the model for `locale` if needed.
    public static func ensureModel(
        for locale: Locale,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard isAvailable else {
            throw PipelineError(
                code: .unsupportedLocale,
                message: "On-device speech transcription is unavailable on this Mac.",
                stage: .transcribed
            )
        }
        let resolved = try await resolveLocale(locale)
        let transcriber = makeTranscriber(locale: resolved)

        // Reserving keeps the locale's assets allocated to this app.
        _ = try? await AssetInventory.reserve(locale: resolved)

        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw modelDownloadError(error)
        }
        // A nil request means everything needed is already installed.
        guard let request else { return }

        onProgress(0)
        let poller = Task {
            while !Task.isCancelled {
                onProgress(min(max(request.progress.fractionCompleted, 0), 1))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }

        do {
            try await request.downloadAndInstall()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw modelDownloadError(error)
        }
        onProgress(1)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            // Timestamps are the whole point: they are what lets merging line the
            // text up against the diarizer's speaker spans.
            attributeOptions: [.audioTimeRange]
        )
    }

    public static func displayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier(.bcp47)
    }

    private static func modelDownloadError(_ error: Error) -> PipelineError {
        PipelineError(
            code: .modelDownloadFailed,
            message: "The speech model could not be downloaded. Check your internet "
                + "connection and try again. (\(error.localizedDescription))",
            stage: .transcribed
        )
    }
}
