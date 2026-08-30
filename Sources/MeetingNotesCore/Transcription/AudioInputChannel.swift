import Foundation
import Speech

/// Bounded hand-off between the file reader and `SpeechAnalyzer`.
///
/// `AsyncStream` buffers without limit, which would let the decoder run the whole
/// file into memory ahead of the (much slower) analyzer. This channel blocks the
/// producer once `capacity` buffers are queued.
actor AudioInputBuffer {
    private var queue: [AnalyzerInput] = []
    private var isFinished = false
    private var waitingConsumer: CheckedContinuation<AnalyzerInput?, Never>?
    private var waitingProducer: CheckedContinuation<Void, Never>?
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func send(_ input: AnalyzerInput) async {
        while queue.count >= capacity, !isFinished {
            await withCheckedContinuation { continuation in
                waitingProducer = continuation
            }
        }
        guard !isFinished else { return }

        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: input)
        } else {
            queue.append(input)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: nil)
        }
        if let producer = waitingProducer {
            waitingProducer = nil
            producer.resume()
        }
    }

    func next() async -> AnalyzerInput? {
        if !queue.isEmpty {
            let item = queue.removeFirst()
            if let producer = waitingProducer {
                waitingProducer = nil
                producer.resume()
            }
            return item
        }
        if isFinished { return nil }
        return await withCheckedContinuation { continuation in
            waitingConsumer = continuation
        }
    }
}

/// `AsyncSequence` face of `AudioInputBuffer`, in the shape `SpeechAnalyzer` wants.
struct AudioInputChannel: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    let buffer: AudioInputBuffer

    struct Iterator: AsyncIteratorProtocol {
        let buffer: AudioInputBuffer
        mutating func next() async -> AnalyzerInput? { await buffer.next() }
    }

    func makeAsyncIterator() -> Iterator { Iterator(buffer: buffer) }
}
