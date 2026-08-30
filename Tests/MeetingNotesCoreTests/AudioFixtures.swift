import AVFoundation
import Foundation

/// Synthesizes small audio files on disk so decode/import tests stay hermetic —
/// no checked-in binaries, no network, no `say`.
enum AudioFixtures {

    /// Writes a stereo 44.1 kHz WAV containing a sine tone.
    @discardableResult
    static func writeSineWAV(
        to url: URL,
        seconds: Double = 1.0,
        sampleRate: Double = 44_100,
        frequency: Double = 440
    ) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount

        let channels = buffer.floatChannelData!
        for frame in 0..<Int(frameCount) {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / sampleRate)) * 0.5
            channels[0][frame] = value
            channels[1][frame] = value
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    /// A temporary directory the caller is responsible for removing.
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MeetingNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
