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
                // Uncancellable: suspended on a callback that cancellation
                // never reaches, the way a provider that ignores it behaves.
                // (Awaiting, not blocking — a blocked thread would starve
                // the timer on a two-core CI runner and test nothing real.)
                await uncancellableWait(seconds: 10)
                return 1
            }
            Issue.record("expected a timeout")
        } catch {
            #expect(error as? CleanupError == .timedOut)
        }
        // Far sooner than the 10 s the work takes; generous for a loaded
        // two-core CI runner, where scheduling alone can take a second.
        #expect(started.duration(to: .now) < .seconds(5))
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

/// Suspends for `seconds` on a dispatch timer; task cancellation cannot
/// resume it early.
private func uncancellableWait(seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume()
        }
    }
}
