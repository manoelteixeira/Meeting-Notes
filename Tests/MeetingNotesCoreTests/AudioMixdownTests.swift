import CoreAudio
import Testing

@testable import MeetingNotesCore

@Suite("Audio mixdown")
struct AudioMixdownTests {

    /// Runs `mix` over buffers built from interleaved sample arrays, one array
    /// per buffer with its channel count, and returns the output and levels.
    private func mix(
        _ buffers: [(channels: Int, samples: [Float])],
        microphoneBuffers: Int
    ) -> (output: [Float], levels: AudioLevels) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        defer {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, buffer) in buffers.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: buffer.samples.count)
            data.initialize(from: buffer.samples, count: buffer.samples.count)
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(buffer.channels),
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: data
            )
        }
        let frames = buffers[0].samples.count / buffers[0].channels
        var output = [Float](repeating: .nan, count: frames)
        let levels = output.withUnsafeMutableBufferPointer {
            AudioMixdown.mix(
                list, microphoneBufferCount: microphoneBuffers,
                frameCount: frames, into: $0.baseAddress!
            )
        }
        return (output, levels)
    }

    @Test("A mono mic on its own passes through unchanged, with no system level")
    func micOnly() {
        let (output, levels) = mix([(1, [0.1, -0.4, 0.25])], microphoneBuffers: 1)
        #expect(output == [0.1, -0.4, 0.25])
        #expect(levels == AudioLevels(microphone: 0.4, system: nil))
    }

    @Test("Mic and system audio are summed, each averaged across its own channels")
    func sumsSources() {
        let (output, levels) = mix(
            [
                (1, [0.2, 0.2]),
                // Stereo tap, interleaved L R L R.
                (2, [0.4, 0.0, -0.2, -0.6]),
            ],
            microphoneBuffers: 1
        )
        #expect(abs(output[0] - 0.4) < 1e-6)   // 0.2 + (0.4 + 0) / 2
        #expect(abs(output[1] - -0.2) < 1e-6)  // 0.2 + (-0.2 - 0.6) / 2
        #expect(levels.microphone == 0.2)
        #expect(abs((levels.system ?? 0) - 0.4) < 1e-6)
    }

    @Test("Loud overlapping speech is clamped to full scale")
    func clamps() {
        let (output, _) = mix([(1, [0.9, -0.9]), (1, [0.8, -0.8])], microphoneBuffers: 1)
        #expect(output == [1, -1])
    }

    @Test("Silence on the tap still reports a system level of zero, not nil")
    func silentTap() {
        let (_, levels) = mix([(1, [0.5]), (2, [0, 0])], microphoneBuffers: 1)
        #expect(levels.system == 0)
    }
}
