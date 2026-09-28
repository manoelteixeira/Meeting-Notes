import CoreAudio

/// Peak level of each source in one stretch of recorded audio, 0 to 1.
public struct AudioLevels: Sendable, Equatable {
    public var microphone: Float
    /// `nil` when the recording carries no system audio at all.
    public var system: Float?

    public init(microphone: Float, system: Float?) {
        self.microphone = microphone
        self.system = system
    }
}

/// Folds what a recording device delivers into the one mono track the
/// pipeline wants.
///
/// The recorder's aggregate device hands over its input as a buffer list: the
/// microphone's streams first, then the system-audio tap's. Each source is
/// averaged across its own channels — so a stereo tap is no louder than a mono
/// mic — and the two sources are summed, since both sides of a call matter
/// equally. The sum is clamped to full scale: overlapping speech clipping
/// briefly beats halving everyone's level all the time.
///
/// Runs on the realtime IO thread, so it never allocates or locks.
public enum AudioMixdown {

    /// Mixes `frameCount` frames starting at `startFrame` into `output`.
    ///
    /// - Parameters:
    ///   - input: interleaved Float32 buffers, microphone first.
    ///   - microphoneBufferCount: how many leading buffers belong to the mic;
    ///     the rest are system audio.
    ///   - output: at least `frameCount` floats.
    public static func mix(
        _ input: UnsafeMutableAudioBufferListPointer,
        microphoneBufferCount: Int,
        startFrame: Int = 0,
        frameCount: Int,
        into output: UnsafeMutablePointer<Float>
    ) -> AudioLevels {
        let micBuffers = 0..<min(microphoneBufferCount, input.count)
        let systemBuffers = micBuffers.upperBound..<input.count
        let micChannels = channelCount(input, micBuffers)
        let systemChannels = channelCount(input, systemBuffers)

        var micPeak: Float = 0
        var systemPeak: Float = 0
        for frame in startFrame..<(startFrame + frameCount) {
            let mic = average(input, micBuffers, channels: micChannels, frame: frame)
            let system = average(input, systemBuffers, channels: systemChannels, frame: frame)
            micPeak = max(micPeak, abs(mic))
            systemPeak = max(systemPeak, abs(system))
            output[frame - startFrame] = min(max(mic + system, -1), 1)
        }
        return AudioLevels(
            microphone: min(micPeak, 1),
            system: systemChannels > 0 ? min(systemPeak, 1) : nil
        )
    }

    private static func channelCount(
        _ input: UnsafeMutableAudioBufferListPointer, _ buffers: Range<Int>
    ) -> Int {
        var total = 0
        for index in buffers { total += Int(input[index].mNumberChannels) }
        return total
    }

    private static func average(
        _ input: UnsafeMutableAudioBufferListPointer,
        _ buffers: Range<Int>,
        channels: Int,
        frame: Int
    ) -> Float {
        guard channels > 0 else { return 0 }
        var sum: Float = 0
        for index in buffers {
            let buffer = input[index]
            let width = Int(buffer.mNumberChannels)
            guard width > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            // A buffer shorter than the frame asked for contributes silence.
            let base = frame * width
            guard base + width <= Int(buffer.mDataByteSize) / MemoryLayout<Float>.size else {
                continue
            }
            for channel in 0..<width { sum += data[base + channel] }
        }
        return sum / Float(channels)
    }
}
