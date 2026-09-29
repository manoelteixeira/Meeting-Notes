import Foundation
import Synchronization
import Testing

@testable import MeetingNotesCore

@Suite("Preparation gate")
struct PreparationGateTests {

    private struct Offline: Error {}

    @Test("Preparation runs once and every caller shares it")
    func sharedOnce() async throws {
        let gate = PreparationGate()
        let attempts = Mutex(0)
        let load: @Sendable () async throws -> Void = {
            attempts.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(30))
        }

        async let first: Void = gate.run(load)
        async let second: Void = gate.run(load)
        _ = try await (first, second)
        try await gate.run(load)

        #expect(attempts.withLock { $0 } == 1)
    }

    @Test("After a failure the waiters retry once, together")
    func retryIsShared() async throws {
        let gate = PreparationGate()
        let attempts = Mutex(0)

        // The first attempt fails while two more callers are waiting on it.
        let failing = Task {
            try await gate.run {
                attempts.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(40))
                throw Offline()
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let succeeding: @Sendable () async throws -> Void = {
            attempts.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(30))
        }
        async let waiterA: Void = gate.run(succeeding)
        async let waiterB: Void = gate.run(succeeding)

        await #expect(throws: Offline.self) { try await failing.value }
        _ = try await (waiterA, waiterB)

        // One failed load plus one shared retry, not one retry per waiter.
        #expect(attempts.withLock { $0 } == 2)
    }
}
