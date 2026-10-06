import CleanupKit
import Foundation
import Testing

/// docs/17 §11: the command deadline holds even for work that ignores
/// cancellation.
struct DeadlineTests {
    @Test func returnsTheResultWhenTheWorkIsFast() async throws {
        let value = try await Deadline.run(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func throwsAtTheLimitEvenWhenTheWorkIgnoresCancellation() async {
        let started = ContinuousClock.now
        do {
            _ = try await Deadline.run(.milliseconds(100)) { () -> Int in
                // Uncancellable: a plain blocking wait, the way a provider
                // that never checks for cancellation behaves.
                blockingWait(seconds: 2)
                return 1
            }
            Issue.record("expected a timeout")
        } catch {
            #expect(error as? CleanupError == .timedOut)
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test func passesTheWorksErrorThrough() async {
        struct Boom: Error {}
        do {
            _ = try await Deadline.run(.seconds(5)) { () -> Int in throw Boom() }
            Issue.record("expected Boom")
        } catch {
            #expect(error is Boom)
        }
    }
}

/// A synchronous wait no cancellation can interrupt.
private func blockingWait(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}
