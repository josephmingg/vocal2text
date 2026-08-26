import BridgeKit
import SwiftUI
import WidgetKit

import ActivityKit

/// The recording indicator: Dynamic Island while the phone is in use, Lock
/// Screen banner when it is not (docs/02 FR-i1.3, AC-i6).
///
/// Every string here comes from `RecordingActivityPresenter`, which Linux CI
/// tests — the widget only decides layout. The one exception is the running
/// timer, which uses `Text(timerInterval:)` so it ticks without the app being
/// awake to push updates.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VocalRecordingAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: RecordingActivityPresenter.symbolName(for: context.state))
                        .font(.title2)
                        .foregroundStyle(tint(for: context.state))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(for: context.state)
                        .font(.title3.monospacedDigit())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecordingActivityPresenter.title(for: context.state))
                            .font(.headline)
                        Text(RecordingActivityPresenter.subtitle(for: context.state))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: RecordingActivityPresenter.symbolName(for: context.state))
                    .foregroundStyle(tint(for: context.state))
            } compactTrailing: {
                timer(for: context.state)
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: RecordingActivityPresenter.symbolName(for: context.state))
                    .foregroundStyle(tint(for: context.state))
            }
            .widgetURL(VocalURL.dictate.url)
        }
    }

    // MARK: - Pieces

    private func lockScreen(_ state: RecordingActivityState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: RecordingActivityPresenter.symbolName(for: state))
                .font(.title2)
                .foregroundStyle(tint(for: state))
            VStack(alignment: .leading, spacing: 2) {
                Text(RecordingActivityPresenter.title(for: state))
                    .font(.headline)
                Text(RecordingActivityPresenter.subtitle(for: state))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            timer(for: state)
                .font(.title3.monospacedDigit())
        }
        .padding()
    }

    /// A live-ticking timer while the take runs; the finished verdict after.
    @ViewBuilder
    private func timer(for state: RecordingActivityState) -> some View {
        if RecordingActivityPresenter.isLive(state) {
            // The system ticks this on its own — a Live Activity cannot rely on
            // the app being scheduled once per second.
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text(RecordingActivityPresenter.compactTrailing(for: state, at: state.startedAt))
                .lineLimit(1)
        }
    }

    private func tint(for state: RecordingActivityState) -> Color {
        switch state.stage {
        case .recording: .red
        case .transcribing, .cleaning, .delivering: .orange
        case .finished: .green
        case .failed: .yellow
        }
    }
}

