import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Records the microphone and, optionally, everything other apps are playing
/// — the far side of a call — into one mono file.
///
/// Both sources come through a single private aggregate device: the default
/// input device as its main sub-device, plus a Core Audio process tap on
/// system output that excludes this app (so transcript playback is never
/// recorded). One IO callback then delivers both on one clock, with the tap
/// drift-compensated onto the mic's, which is what keeps the two sides of a
/// conversation aligned over an hour.
///
/// The file is 16-bit PCM in a CAF container at up to 24 kHz. Uncompressed on
/// purpose: a CAF of PCM whose writer never closed is still readable end to
/// end, so a crash or force quit costs nothing already recorded. That is
/// ~170 MB an hour; speech needs no more than 24 kHz, and the pipeline itself
/// decodes to 16 kHz.
///
/// Not an actor: Core Audio calls back on its own thread, and start/stop are
/// driven from the main actor. `lock` guards the session.
public final class MeetingRecorder: @unchecked Sendable {

    public enum RecorderError: Error, LocalizedError {
        case noInputDevice
        case alreadyRecording
        case coreAudio(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "No microphone is available. Connect one, or choose an input in System Settings › Sound."
            case .alreadyRecording:
                "A recording is already in progress."
            case .coreAudio(let step, let status):
                "The recording could not be started (\(step), error \(status))."
            }
        }
    }

    /// What `start` managed to set up.
    public struct Started: Sendable {
        /// False when system audio was asked for but the tap could not be made;
        /// the recording then carries the microphone alone.
        public var capturesSystemAudio: Bool
    }

    private let lock = NSLock()
    private var session: Session?

    public init() {}

    public var isRecording: Bool { lock.withLock { session != nil } }

    /// Peak levels since the last call, for a meter polled from the UI.
    public func takeLevels() -> AudioLevels? {
        lock.withLock { session?.context?.takeLevels() }
    }

    public func start(to url: URL, includeSystemAudio: Bool) throws -> Started {
        try lock.withLock {
            guard session == nil else { throw RecorderError.alreadyRecording }
            let session = try Session(url: url, includeSystemAudio: includeSystemAudio)
            self.session = session
            return Started(capturesSystemAudio: session.tap != nil)
        }
    }

    /// Stops and finalizes the file. Returns its URL, or `nil` if nothing was
    /// recording.
    @discardableResult
    public func stop() -> URL? {
        let session = lock.withLock {
            defer { self.session = nil }
            return self.session
        }
        guard let session else { return nil }
        session.tearDown()
        return session.url
    }

    /// Stops and deletes the file.
    public func discard() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Session

/// One recording's Core Audio objects, torn down in reverse order of creation.
private final class Session {
    let url: URL
    private(set) var context: IOContext?
    private(set) var tap: AudioObjectID?
    private var aggregate: AudioObjectID = kAudioObjectUnknown
    private var procID: AudioDeviceIOProcID?
    private var file: ExtAudioFileRef?

    init(url: URL, includeSystemAudio: Bool) throws {
        self.url = url
        let mic: AudioDeviceID = try CoreAudioProperty.read(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice
        )
        guard mic != kAudioObjectUnknown else { throw MeetingRecorder.RecorderError.noInputDevice }
        let micUID: CFString = try CoreAudioProperty.read(mic, kAudioDevicePropertyDeviceUID)
        let micBuffers = CoreAudioProperty.count(
            mic, kAudioDevicePropertyStreams, of: AudioStreamID.self,
            scope: kAudioObjectPropertyScopeInput
        )

        // From here on every failure has to release what was already made.
        do {
            var tapUID: String?
            if includeSystemAudio, let (tapID, uid) = Self.makeTap() {
                tap = tapID
                tapUID = uid
            }
            aggregate = try Self.makeAggregate(micUID: micUID as String, tapUID: tapUID)

            let rate: Float64 = try CoreAudioProperty.read(
                aggregate, kAudioDevicePropertyNominalSampleRate
            )
            let bufferFrames: UInt32 = (try? CoreAudioProperty.read(
                aggregate, kAudioDevicePropertyBufferFrameSize
            )) ?? 4096
            let file = try Self.makeFile(url: url, sampleRate: rate)
            self.file = file
            let context = IOContext(
                file: file,
                microphoneBufferCount: micBuffers,
                capacity: max(Int(bufferFrames), 4096)
            )
            self.context = context
            try start(context)
        } catch {
            tearDown()
            throw error
        }
    }

    private func start(_ context: IOContext) throws {
        var procID: AudioDeviceIOProcID?
        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregate, nil
        ) { _, input, _, _, _ in
            context.process(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        })
        self.procID = procID
        try check("start device", AudioDeviceStart(aggregate, procID))
    }

    func tearDown() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
        if let file {
            // Flushes the async writer and finalizes the file.
            ExtAudioFileDispose(file)
            self.file = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = kAudioObjectUnknown
        }
        if let tap {
            AudioHardwareDestroyProcessTap(tap)
            self.tap = nil
        }
    }

    /// A stereo tap on everything playing, except this process. Returns nil
    /// rather than throwing: losing system audio should downgrade the
    /// recording, not prevent it.
    private static func makeTap() -> (AudioObjectID, String)? {
        var excluded: [AudioObjectID] = []
        var pid = ProcessInfo.processInfo.processIdentifier
        if let own: AudioObjectID = try? CoreAudioProperty.read(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject,
            qualifier: &pid
        ), own != kAudioObjectUnknown {
            excluded.append(own)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Meeting Notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
              tapID != kAudioObjectUnknown
        else { return nil }
        return (tapID, description.uuid.uuidString)
    }

    private static func makeAggregate(micUID: String, tapUID: String?) throws -> AudioObjectID {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Notes Recorder",
            kAudioAggregateDeviceUIDKey: "com.meetingnotes.recorder.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
        ]
        if let tapUID {
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(
            "create aggregate device",
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        )
        return aggregate
    }

    /// Mono 16-bit PCM at the device's rate, capped at 24 kHz. The converter
    /// resamples if it has to.
    private static func makeFile(url: URL, sampleRate: Float64) throws -> ExtAudioFileRef {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: min(sampleRate, 24_000),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var file: ExtAudioFileRef?
        try check("create file", ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileFormat, nil,
            AudioFileFlags.eraseFile.rawValue, &file
        ))
        guard let file else { throw MeetingRecorder.RecorderError.coreAudio("create file", -1) }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        do {
            try check("set client format", ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
            ))
            // Priming allocates the async writer's buffers here, off the IO thread.
            try check("prime writer", ExtAudioFileWriteAsync(file, 0, nil))
        } catch {
            ExtAudioFileDispose(file)
            throw error
        }
        return file
    }
}

// MARK: - IO context

/// Everything the IO callback touches. Preallocated, so the callback never
/// allocates; levels cross threads through atomics.
private final class IOContext: @unchecked Sendable {
    private let file: ExtAudioFileRef
    private let microphoneBufferCount: Int
    private let capacity: Int
    private let scratch: UnsafeMutablePointer<Float>
    private let micPeak = Atomic<UInt32>(0)
    /// Bit pattern of the peak, or `UInt32.max` while no tap is present.
    private let systemPeak = Atomic<UInt32>(0)
    private let hasSystem = Atomic<Bool>(false)

    init(file: ExtAudioFileRef, microphoneBufferCount: Int, capacity: Int) {
        self.file = file
        self.microphoneBufferCount = microphoneBufferCount
        self.capacity = capacity
        self.scratch = .allocate(capacity: capacity)
    }

    deinit { scratch.deallocate() }

    func process(_ input: UnsafeMutableAudioBufferListPointer) {
        guard let first = input.first, first.mNumberChannels > 0 else { return }
        let totalFrames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        var start = 0
        while start < totalFrames {
            let frames = min(capacity, totalFrames - start)
            let levels = AudioMixdown.mix(
                input, microphoneBufferCount: microphoneBufferCount,
                startFrame: start, frameCount: frames, into: scratch
            )
            record(levels)

            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(scratch)
                )
            )
            ExtAudioFileWriteAsync(file, UInt32(frames), &list)
            start += frames
        }
    }

    private func record(_ levels: AudioLevels) {
        Self.raise(micPeak, to: levels.microphone)
        if let system = levels.system {
            hasSystem.store(true, ordering: .relaxed)
            Self.raise(systemPeak, to: system)
        }
    }

    /// Peaks since the last call, resetting them.
    func takeLevels() -> AudioLevels {
        let mic = Float(bitPattern: micPeak.exchange(0, ordering: .relaxed))
        let system = Float(bitPattern: systemPeak.exchange(0, ordering: .relaxed))
        return AudioLevels(
            microphone: mic,
            system: hasSystem.load(ordering: .relaxed) ? system : nil
        )
    }

    /// Non-negative floats order the same as their bit patterns, so a plain
    /// integer max works.
    private static func raise(_ atomic: borrowing Atomic<UInt32>, to value: Float) {
        let bits = value.bitPattern
        var current = atomic.load(ordering: .relaxed)
        while bits > current {
            let (exchanged, original) = atomic.compareExchange(
                expected: current, desired: bits, ordering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }
}

// MARK: - Property helpers

private func check(_ step: String, _ status: OSStatus) throws {
    guard status == noErr else { throw MeetingRecorder.RecorderError.coreAudio(step, status) }
}

private enum CoreAudioProperty {
    static func read<Value>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        qualifier: UnsafeMutablePointer<pid_t>? = nil
    ) throws -> Value {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let qualifierSize = qualifier == nil ? 0 : UInt32(MemoryLayout<pid_t>.size)
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        try check("read property", AudioObjectGetPropertyData(
            object, &address, qualifierSize, qualifier, &size, pointer
        ))
        return pointer.move()
    }

    /// Number of elements in an array-valued property, e.g. a device's streams.
    static func count<Element>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        of _: Element.Type,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<Element>.size
    }
}
