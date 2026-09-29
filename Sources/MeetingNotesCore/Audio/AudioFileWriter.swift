import AVFoundation
import Foundation

/// Writes mono PCM to disk, for the per-speaker tracks the transcriber reads.
public enum AudioFileWriter {

    /// Writes `samples` as a 16-bit mono WAV at `sampleRate`.
    ///
    /// Written in chunks so an hour-long track never needs one buffer the
    /// size of the whole file.
    public static func writeMonoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
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

        let chunk = 1 << 20
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw PipelineError.unsupportedAudio("Could not allocate an output buffer.")
            }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + offset, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }
}
