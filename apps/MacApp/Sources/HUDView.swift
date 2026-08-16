import Foundation
import SwiftUI

/// SwiftUI content of the recording HUD (FR-4.1/FR-4.2). The hosting `NSPanel`
/// keeps a constant frame; every mode change morphs inside it (docs/03 §3.4).
struct HUDView: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(
            width: HUDPanelController.panelSize.width,
            height: HUDPanelController.panelSize.height
        )
        // Dark capsule regardless of system theme (panel appearance matches).
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Mode content

    @ViewBuilder
    private var content: some View {
        switch appState.hudState.mode {
        case .hidden:
            EmptyView()
        case .listening(let startedAt):
            listening(startedAt: startedAt)
        case .processing:
            processing
        case .error(let message):
            errorContent(message)
        case .notice(let message):
            noticeContent(message)
        }
    }

    private func noticeContent(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
    }

    private func listening(startedAt: Date) -> some View {
        // One timeline drives the timer, the pulsing dot, and the placeholder
        // waveform; Reduce Motion drops it to 1 Hz (timer ticks only, NFR-5).
        TimelineView(.periodic(from: startedAt, by: reduceMotion ? 1.0 : 0.1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    recordingDot(elapsed: elapsed)
                    WaveformView(levels: placeholderLevels(elapsed: elapsed))
                        .frame(width: 140, height: 26)
                    Text(Self.timerString(elapsed: elapsed))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if !appState.hudState.profileName.isEmpty {
                        Text(appState.hudState.profileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    languageBadge
                    if appState.hudState.isRemoteCleanup {
                        cloudBadge
                    }
                }
                partialLine
            }
        }
    }

    private var processing: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text("Transcribing…")
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }

    private func errorContent(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    // MARK: - Listening pieces

    private func recordingDot(elapsed: TimeInterval) -> some View {
        let pulse = reduceMotion ? 1.0 : 0.55 + 0.45 * ((sin(elapsed * 2 * .pi / 1.2) + 1) / 2)
        return Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(pulse)
            .accessibilityLabel("Recording")
    }

    private var languageBadge: some View {
        Text(appState.hudState.languageLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    /// Persistent privacy badge while a remote cleanup provider is active
    /// (FR-7.4).
    private var cloudBadge: some View {
        Image(systemName: "cloud.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Cleanup uses a remote provider")
            .accessibilityLabel("Remote cleanup active")
    }

    private var partialLine: some View {
        // Preview only — committed text always comes from the full-utterance
        // pass (FR-4.1). Space placeholder keeps the row height stable.
        Text(appState.hudState.partialText.isEmpty ? " " : appState.hudState.partialText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    /// Placeholder waveform levels until AppState publishes live microphone
    /// levels (follow-up): a gentle deterministic ripple, frozen to the idle
    /// baseline when Reduce Motion is on.
    private func placeholderLevels(elapsed: TimeInterval) -> [Float] {
        guard !reduceMotion else { return [] }
        return (0..<WaveformView.barCount).map { index in
            let phase = elapsed * 2.4 + Double(index) * 0.55
            let wave = (sin(phase) + 1) / 2
            return Float(0.12 + 0.18 * wave)
        }
    }

    private static func timerString(elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
