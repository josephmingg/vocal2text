import BridgeKit
import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Drives the Dynamic Island / Lock Screen recording indicator for one take
/// at a time (docs/02 FR-i1.3).
///
/// Every method is a no-op when Live Activities are switched off for the app,
/// so a take never fails because the indicator could not start. Note the
/// inverse is *not* true on the Control Center path: an `AudioRecordingIntent`
/// must start an activity or iOS stops the recording (docs/03 §6), which is
/// why `start` is called before capture rather than after.
///
/// All four entry points are synchronous. That is deliberate: teardown
/// releases the handle before it awaits, so a take started immediately after a
/// cancelled one still gets its own indicator instead of finding the old
/// handle still in place.
@MainActor
final class LiveActivityController {

    /// How the indicator should disappear once the take is over.
    enum Dismissal {
        /// Leave the final state glanceable for a few seconds.
        case afterGracePeriod
        /// Take it away now — the take was thrown away.
        case immediate
    }

    private var activity: Activity<VocalRecordingAttributes>?

    /// Finished activities linger briefly so the transcript stays glanceable.
    private static let dismissAfter: TimeInterval = 8

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(takeID: String, state: RecordingActivityState) {
        guard isSupported, activity == nil else { return }
        activity = try? Activity.request(
            attributes: VocalRecordingAttributes(takeID: takeID),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    func update(_ state: RecordingActivityState) {
        guard let activity else { return }
        let handle = Handle(activity)
        Task { await handle.update(state) }
    }

    /// Ends the activity, leaving the final state visible for a few seconds.
    func finish(with state: RecordingActivityState) {
        end(state: state, dismissal: .afterGracePeriod)
    }

    /// Tears the activity down immediately — used when a take is cancelled.
    func dismiss() {
        end(state: nil, dismissal: .immediate)
    }

    /// Releases the handle *synchronously*, then ends the activity in the
    /// background.
    ///
    /// The ordering is the point: if the handle were only cleared after the
    /// `await`, a user who cancels a take and immediately starts another would
    /// find `start` refusing (the old handle is still there) while the queued
    /// teardown ends the old activity anyway — the second take would run with
    /// no indicator at all.
    private func end(state: RecordingActivityState?, dismissal: Dismissal) {
        guard let activity else { return }
        self.activity = nil
        let handle = Handle(activity)
        let deadline = Date().addingTimeInterval(Self.dismissAfter)
        Task { await handle.end(state: state, dismissal: dismissal, deadline: deadline) }
    }

    /// Carries an `Activity` across an isolation boundary.
    ///
    /// ActivityKit's `Activity` is not `Sendable`, but `update` and `end` are
    /// `nonisolated async`, so Swift 6 refuses to let a main-actor-held handle
    /// reach them. The handle here is written and read only on the main actor
    /// and is handed to exactly one task, which is what makes the unchecked
    /// conformance sound; ActivityKit itself documents these calls as safe
    /// from any context.
    private struct Handle: @unchecked Sendable {
        private let activity: Activity<VocalRecordingAttributes>

        init(_ activity: Activity<VocalRecordingAttributes>) {
            self.activity = activity
        }

        func update(_ state: RecordingActivityState) async {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        func end(
            state: RecordingActivityState?,
            dismissal: Dismissal,
            deadline: Date
        ) async {
            let content = state.map { ActivityContent(state: $0, staleDate: nil) }
            switch dismissal {
            case .afterGracePeriod:
                await activity.end(content, dismissalPolicy: .after(deadline))
            case .immediate:
                await activity.end(content, dismissalPolicy: .immediate)
            }
        }
    }
}

#else

/// Platforms without ActivityKit still compile the app; the indicator is
/// simply absent.
@MainActor
final class LiveActivityController {
    var isSupported: Bool { false }
    func start(takeID: String, state: RecordingActivityState) {}
    func update(_ state: RecordingActivityState) {}
    func finish(with state: RecordingActivityState) {}
    func dismiss() {}
}

#endif
