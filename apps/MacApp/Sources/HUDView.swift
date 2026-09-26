import Foundation
import SwiftUI

/// SwiftUI content of the recording HUD (FR-4.1/FR-4.2). The hosting `NSPanel`
/// keeps a constant frame; every mode change morphs inside it (docs/03 §3.4).
struct HUDView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A disabled HUD draws nothing, so no animation ticks off-screen.
        if !settings.hudEnabled {
            EmptyView()
        } else {
            styled
        }
    }

    @ViewBuilder
    private var styled: some View {
        switch settings.hudStyle {
        case .jarvis:
            JarvisHUDView(state: appState.hudState)
        case .classic:
            classic
        }
    }

    private var classic: some View {
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
        case .processing(let stage):
            processing(stage: stage)
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
                    WaveformView(levels: waveformLevels)
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

    private func processing(stage: HUDState.ProcessingStage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // docs/15 step 23: the delivering beat is visibly distinct —
                // the moment between "thinking" and "text landed" used to be
                // one undifferentiated spinner.
                if stage == .delivering {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
                Text(Self.stageLabel(stage))
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            // First-run honesty and the live preview both arrive via
            // partialText, so a long stage never looks frozen.
            if !appState.hudState.partialText.isEmpty {
                Text(appState.hudState.partialText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private static func stageLabel(_ stage: HUDState.ProcessingStage) -> String {
        switch stage {
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        case .delivering: return "Inserting…"
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

    /// Live microphone levels (FR-4.1). Reduce Motion freezes the bars at the
    /// idle baseline rather than animating with the voice; the level itself is
    /// still captured, it is simply not drawn as movement.
    private var waveformLevels: [Float] {
        guard !reduceMotion else { return [] }
        return appState.hudState.levels
    }

    private static func timerString(elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
