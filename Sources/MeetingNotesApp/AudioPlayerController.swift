import AVFoundation
import Foundation
import MeetingNotesCore
import Observation

/// Plays one meeting's audio and tracks where in the transcript it is.
///
/// Deliberately separate from `AppModel`: the clock ticks at 10 Hz while
/// playing, and only the player bar should re-render that often. The transcript
/// list reads `currentSegmentID`, which changes only when playback crosses a
/// segment boundary.
@MainActor
@Observable
final class AudioPlayerController {

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Segment containing (or most recently started before) the playhead.
    private(set) var currentSegmentID: UUID?
    /// The audio file could not be opened — corrupt, or removed from disk.
    private(set) var loadFailed = false
    /// Segment being played on its own; playback pauses at its end.
    private(set) var soloSegmentID: UUID?

    /// Playback level, 0 to 1. Remembered across launches.
    var volume: Double {
        didSet {
            player?.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: Self.volumeDefaultsKey)
        }
    }

    /// Playback speed multiplier. Remembered across launches.
    var rate: Double {
        didSet {
            player?.rate = Float(rate)
            UserDefaults.standard.set(rate, forKey: Self.rateDefaultsKey)
        }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var segments: [TranscriptSegment] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var stopAt: TimeInterval?
    @ObservationIgnored private var delegateProxy: DelegateProxy?

    private static let volumeDefaultsKey = "playbackVolume"
    private static let rateDefaultsKey = "playbackRate"

    init() {
        let defaults = UserDefaults.standard
        volume = defaults.object(forKey: Self.volumeDefaultsKey) as? Double ?? 1
        rate = defaults.object(forKey: Self.rateDefaultsKey) as? Double ?? 1
    }

    /// Replaces whatever was playing with this meeting's audio, stopped at 0.
    func load(url: URL, segments: [TranscriptSegment], fallbackDuration: TimeInterval) {
        stop()
        self.segments = segments
        currentTime = 0
        currentSegmentID = nil
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            // Must be enabled before playback ever starts for live speed changes.
            player.enableRate = true
            player.rate = Float(rate)
            player.volume = Float(volume)
            player.prepareToPlay()
            let proxy = DelegateProxy { [weak self] in self?.playbackFinished() }
            player.delegate = proxy
            self.player = player
            self.delegateProxy = proxy
            duration = player.duration > 0 ? player.duration : fallbackDuration
            loadFailed = false
        } catch {
            player = nil
            delegateProxy = nil
            duration = fallbackDuration
            loadFailed = true
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        // The bar always plays continuously; a solo bound would stop it short.
        clearSolo()
        if isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            // Finished playback parks the playhead at the end; play restarts.
            if player.currentTime >= player.duration, player.duration > 0 {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
            startTimer()
            tick()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        clearSolo()
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
        updateCurrentSegment(at: clamped)
    }

    /// Plays just this utterance, pausing at its end. Pressing again while it
    /// plays pauses immediately.
    func playSegment(_ segment: TranscriptSegment) {
        guard let player else { return }
        if soloSegmentID == segment.id, isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
            clearSolo()
            return
        }
        player.currentTime = min(max(0, segment.start), player.duration)
        currentTime = player.currentTime
        updateCurrentSegment(at: currentTime)
        stopAt = segment.end
        soloSegmentID = segment.id
        player.play()
        isPlaying = true
        startTimer()
    }

    /// While the user drags the slider, the clock must not fight the knob.
    func beginScrubbing() {
        isScrubbing = true
    }

    func endScrubbing(at time: TimeInterval) {
        isScrubbing = false
        seek(to: time)
    }

    func stop() {
        player?.stop()
        player = nil
        delegateProxy = nil
        isPlaying = false
        clearSolo()
        stopTimer()
    }

    // MARK: - Clock

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes, so the clock keeps running during slider drags.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player, !isScrubbing else { return }
        currentTime = player.currentTime
        updateCurrentSegment(at: player.currentTime)
        if let stopAt, currentTime >= stopAt {
            player.pause()
            isPlaying = false
            clearSolo()
            stopTimer()
        }
    }

    private func clearSolo() {
        stopAt = nil
        if soloSegmentID != nil {
            soloSegmentID = nil
        }
    }

    private func updateCurrentSegment(at time: TimeInterval) {
        let id = segments.segmentIndex(at: time).map { segments[$0].id }
        if id != currentSegmentID {
            currentSegmentID = id
        }
    }

    private func playbackFinished() {
        isPlaying = false
        clearSolo()
        stopTimer()
        currentTime = duration
    }

    /// AVAudioPlayer's delegate may be called off the main thread, and an
    /// `@Observable` main-actor class cannot be an NSObject delegate itself.
    private final class DelegateProxy: NSObject, AVAudioPlayerDelegate {
        private let onFinish: @MainActor () -> Void

        init(onFinish: @escaping @MainActor () -> Void) {
            self.onFinish = onFinish
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [onFinish] in onFinish() }
        }
    }
}
