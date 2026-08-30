import AVFoundation
import Foundation

/// 16 kHz mono PCM, the format the diarizer expects.
public struct DecodedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: TimeInterval

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// Decodes any AVFoundation-readable audio file to 16 kHz mono Float32.
///
/// `AVAudioFile` handles the common cases directly; `AVAssetReader` covers
/// container formats (notably some mp4/m4a variants) that `AVAudioFile` rejects.
/// If both paths fail the file is genuinely unsupported.
public enum AudioDecoder {
    public static let targetSampleRate: Double = 16_000

    /// Duration in seconds without decoding the whole file.
    public static func probeDuration(url: URL) async throws -> TimeInterval {
        if let file = try? AVAudioFile(forReading: url) {
            let rate = file.fileFormat.sampleRate
            if rate > 0 { return Double(file.length) / rate }
        }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { return seconds }
        } catch {
            throw PipelineError.unsupportedAudio(error.localizedDescription)
        }
        throw PipelineError.unsupportedAudio("Its duration could not be determined.")
    }

    public static func decodeMono16k(url: URL) async throws -> DecodedAudio {
        var firstFailure: String?
        do {
            return try decodeWithAudioFile(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            firstFailure = error.localizedDescription
        }

        do {
            return try await decodeWithAssetReader(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let detail = firstFailure.map { "\($0) \(error.localizedDescription)" }
                ?? error.localizedDescription
            throw PipelineError.unsupportedAudio(detail)
        }
    }

    // MARK: - AVAudioFile path

    private static func decodeWithAudioFile(url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate > 0 else {
            throw PipelineError.unsupportedAudio("The file reports a zero sample rate.")
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PipelineError.unsupportedAudio("The 16 kHz mono output format is unavailable.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PipelineError.unsupportedAudio("No converter exists for this file's format.")
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let inputChunk: AVAudioFrameCount = 16_384
        let outputCapacity = AVAudioFrameCount(Double(inputChunk) * ratio) + 1_024

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + Int(outputCapacity))

        // The converter's input block is typed @Sendable but AVAudioConverter
        // invokes it synchronously on this thread, so plain locals are safe here.
        nonisolated(unsafe) var readerFinished = false
        nonisolated(unsafe) var readError: Error?

        while true {
            try Task.checkCancellation()
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw PipelineError.unsupportedAudio("Could not allocate an output buffer.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if readerFinished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: inputChunk
                ) else {
                    readerFinished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer, frameCount: inputChunk)
                } catch {
                    readError = error
                    readerFinished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    readerFinished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let readError { throw readError }
            if status == .error {
                throw conversionError ?? PipelineError.unsupportedAudio("Audio conversion failed.")
            }

            if outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
                )
            }

            if status == .endOfStream { break }
            // `inputRanDry` with no output would spin forever; treat it as the end.
            if status == .inputRanDry, outputBuffer.frameLength == 0 { break }
        }

        guard !samples.isEmpty else {
            throw PipelineError.unsupportedAudio("The file decoded to zero audio samples.")
        }
        return DecodedAudio(samples: samples, sampleRate: targetSampleRate)
    }

    // MARK: - AVAssetReader path

    private static func decodeWithAssetReader(url: URL) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw PipelineError.unsupportedAudio("It contains no audio track.")
        }

        let reader = try AVAssetReader(asset: asset)
        // Ask AVFoundation itself for interleaved 16 kHz mono Float32, so the
        // block buffers below are already a flat [Float].
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PipelineError.unsupportedAudio("Its audio track cannot be decoded.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PipelineError.unsupportedAudio("Reading the audio track failed.")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }

            let count = length / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: raw.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw PipelineError.unsupportedAudio("Copying decoded audio failed.")
            }
            samples.append(contentsOf: chunk)
        }

        if reader.status == .failed {
            throw reader.error ?? PipelineError.unsupportedAudio("Reading the audio track failed.")
        }
        guard !samples.isEmpty else {
            throw PipelineError.unsupportedAudio("The file decoded to zero audio samples.")
        }
        return DecodedAudio(samples: samples, sampleRate: targetSampleRate)
    }
}
