import AVFoundation
import Foundation

/// Writes mono PCM to disk, for the per-speaker tracks the transcriber reads.
public enum AudioFileWriter {

    /// Writes `samples` as a 16-bit mono WAV at `sampleRate`.
    public static func writeMonoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        try writeMonoWAV(frameCount: samples.count, sampleRate: sampleRate, to: url) { output, frames in
            samples.withUnsafeBufferPointer { source in
                output.baseAddress!.update(from: source.baseAddress! + frames.lowerBound, count: frames.count)
            }
        }
    }

    /// Writes `track`, masked out of `audio`, as a 16-bit mono WAV. The
    /// masked audio is rendered chunk by chunk as it is written, so it never
    /// exists in memory alongside `audio`.
    public static func writeMonoWAV(
        _ track: SpeakerTrackBuilder.Track,
        from audio: DecodedAudio,
        to url: URL
    ) throws {
        try writeMonoWAV(frameCount: audio.samples.count, sampleRate: audio.sampleRate, to: url) { output, frames in
            SpeakerTrackBuilder.fillMasked(
                output,
                frames: frames,
                of: track,
                from: audio.samples,
                sampleRate: audio.sampleRate
            )
        }
    }

    /// Writes `frameCount` frames as a 16-bit mono WAV at `sampleRate`,
    /// asking `fill` for them one chunk at a time.
    ///
    /// One chunk-sized buffer is reused throughout, so the audio never has
    /// to exist in full anywhere: `fill` can render it on demand.
    public static func writeMonoWAV(
        frameCount: Int,
        sampleRate: Double,
        to url: URL,
        fill: (UnsafeMutableBufferPointer<Float>, Range<Int>) -> Void
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PipelineError.unsupportedAudio("The mono output format is unavailable.")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Scoped so the file is closed (and its header finalized) on return.
        let file = try AVAudioFile(forWriting: url, settings: settings)

        let chunk = min(1 << 20, max(frameCount, 1))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunk)
        ), let channel = buffer.floatChannelData?[0] else {
            throw PipelineError.unsupportedAudio("Could not allocate an output buffer.")
        }

        var offset = 0
        while offset < frameCount {
            let count = min(chunk, frameCount - offset)
            fill(UnsafeMutableBufferPointer(start: channel, count: count), offset..<(offset + count))
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }
}
