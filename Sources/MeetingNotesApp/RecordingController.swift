import AVFoundation
import Foundation
import MeetingNotesCore
import Observation

/// Drives the recorder and publishes what the recording bar shows.
///
/// Deliberately separate from `AppModel`, like `AudioPlayerController`: the
/// meters tick at 15 Hz while recording, and only the recording bar should
/// re-render that often.
@MainActor
@Observable
final class RecordingController {

    enum RecordingError: Error, LocalizedError {
        case microphoneDenied

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Meeting Notes doesn't have access to the microphone. Allow it in "
                    + "System Settings › Privacy & Security › Microphone, then try again."
            }
        }
    }

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// Display level of each source, 0 to 1, already shaped for a meter.
    private(set) var microphoneLevel: Double = 0
    /// `nil` when this recording carries no system audio.
    private(set) var systemLevel: Double?
    /// Why the recording is not what was asked for, e.g. system audio missing.
    private(set) var notice: String?

    @ObservationIgnored private let recorder = MeetingRecorder()
    @ObservationIgnored private var timer: Timer?

    func start(to url: URL, includeSystemAudio: Bool) async throws {
        guard !isRecording else { return }
        try await Self.ensureMicrophoneAccess()

        let started = try recorder.start(to: url, includeSystemAudio: includeSystemAudio)
        isRecording = true
        startedAt = Date()
        microphoneLevel = 0
        systemLevel = started.capturesSystemAudio ? 0 : nil
        notice = includeSystemAudio && !started.capturesSystemAudio
            ? "System audio unavailable — recording the microphone only"
            : nil
        startTimer()
    }

    /// Finalizes the file and returns it, or `nil` if nothing was recording.
    func stop() -> URL? {
        guard isRecording else { return nil }
        reset()
        return recorder.stop()
    }

    func discard() {
        guard isRecording else { return }
        reset()
        recorder.discard()
    }

    private func reset() {
        stopTimer()
        isRecording = false
        startedAt = nil
        notice = nil
    }

    private static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default:
            break
        }
        throw RecordingError.microphoneDenied
    }

    // MARK: - Meters

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let levels = recorder.takeLevels() else { return }
        microphoneLevel = Self.meter(levels.microphone)
        if systemLevel != nil, let system = levels.system {
            systemLevel = Self.meter(system)
        }
    }

    /// Maps a linear peak onto a 50 dB meter, so quiet speech still moves it.
    private static func meter(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
