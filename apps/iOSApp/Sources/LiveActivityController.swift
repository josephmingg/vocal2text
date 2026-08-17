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
@MainActor
final class LiveActivityController {

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

    func update(_ state: RecordingActivityState) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// Ends the activity, leaving the final state visible for a few seconds.
    func finish(with state: RecordingActivityState) async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(Self.dismissAfter))
        )
    }

    /// Tears the activity down immediately — used when a take is cancelled.
    func dismiss() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}

#else

/// Platforms without ActivityKit still compile the app; the indicator is
/// simply absent.
@MainActor
final class LiveActivityController {
    var isSupported: Bool { false }
    func start(takeID: String, state: RecordingActivityState) {}
    func update(_ state: RecordingActivityState) async {}
    func finish(with state: RecordingActivityState) async {}
    func dismiss() async {}
}

#endif
