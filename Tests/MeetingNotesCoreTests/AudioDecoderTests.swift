import Foundation
import Testing

@testable import MeetingNotesCore

@Suite("Audio decoding")
struct AudioDecoderTests {

    @Test("A stereo 44.1 kHz file decodes to 16 kHz mono")
    func decodesToMono16k() async throws {
        let directory = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tone.wav", directoryHint: .notDirectory)
        try AudioFixtures.writeSineWAV(to: url, seconds: 2.0, sampleRate: 44_100)

        let decoded = try await AudioDecoder.decodeMono16k(url: url)

        #expect(decoded.sampleRate == 16_000)
        #expect(abs(decoded.duration - 2.0) < 0.05)
        // Roughly 2 s at 16 kHz, allowing for converter tail effects.
        #expect(abs(decoded.samples.count - 32_000) < 800)
        // A 440 Hz tone at half amplitude must survive resampling.
        let peak = decoded.samples.map(abs).max() ?? 0
        #expect(peak > 0.2)
    }

    @Test("Duration is probed without decoding the whole file")
    func probesDuration() async throws {
        let directory = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tone.wav", directoryHint: .notDirectory)
        try AudioFixtures.writeSineWAV(to: url, seconds: 0.75)

        let duration = try await AudioDecoder.probeDuration(url: url)

        #expect(abs(duration - 0.75) < 0.02)
    }

    @Test("A file that is not audio reports unsupportedAudio")
    func rejectsNonAudio() async throws {
        let directory = try AudioFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data("definitely not audio".utf8).write(to: url)

        do {
            _ = try await AudioDecoder.decodeMono16k(url: url)
            Issue.record("Expected decoding to fail")
        } catch let error as PipelineError {
            #expect(error.code == .unsupportedAudio)
        } catch {
            Issue.record("Expected a PipelineError, got \(error)")
        }
    }
}
