import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Audio file writing")
struct AudioFileWriterTests {

    @Test("A written track decodes back to the same audio")
    func roundTrip() async throws {
        let root = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "track.wav", directoryHint: .notDirectory)

        let rate = 16_000.0
        let samples = (0..<Int(rate * 1.5)).map { index in
            Float(sin(2 * .pi * 440 * Double(index) / rate)) * 0.5
        }
        try AudioFileWriter.writeMonoWAV(samples: samples, sampleRate: rate, to: url)

        let decoded = try await AudioDecoder.decodeMono16k(url: url)
        #expect(decoded.samples.count == samples.count)
        #expect(abs(decoded.duration - 1.5) < 0.001)
        // 16-bit quantization only.
        let worst = zip(decoded.samples, samples).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-3)
    }

    @Test("Silence and a very short buffer both write cleanly")
    func edges() async throws {
        let root = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let silent = root.appending(path: "silent.wav", directoryHint: .notDirectory)
        try AudioFileWriter.writeMonoWAV(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, to: silent)
        let decoded = try await AudioDecoder.decodeMono16k(url: silent)
        #expect(decoded.samples.count == 16_000)
        #expect(decoded.samples.allSatisfy { $0 == 0 })

        let tiny = root.appending(path: "tiny.wav", directoryHint: .notDirectory)
        try AudioFileWriter.writeMonoWAV(samples: [0.1, -0.1, 0.2], sampleRate: 16_000, to: tiny)
        #expect(FileManager.default.fileExists(atPath: tiny.path))
    }
}
