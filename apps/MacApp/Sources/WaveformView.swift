import SwiftUI

/// Lightweight bar waveform for the recording HUD (FR-4.1). A pure render of
/// the given levels — any animation comes from the caller re-evaluating with
/// new levels, so Reduce Motion is honored upstream by freezing the input.
struct WaveformView: View {
    var levels: [Float]

    static let barCount = 28

    private static let barSpacing: CGFloat = 2
    /// Baseline drawn when no levels are available (live level plumbing from
    /// AppState is a follow-up).
    private static let idleLevel: CGFloat = 0.08

    var body: some View {
        Canvas { context, size in
            let count = Self.barCount
            let spacing = Self.barSpacing
            let barWidth = max(1, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let midY = size.height / 2
            for index in 0..<count {
                let height = max(barWidth, normalizedLevel(at: index) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: midY - height / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(Color.primary.opacity(0.85))
                )
            }
        }
        .accessibilityHidden(true)
    }

    /// Resamples arbitrary-length input to the fixed bar count; empty input
    /// renders the subtle idle baseline.
    private func normalizedLevel(at index: Int) -> CGFloat {
        guard !levels.isEmpty else { return Self.idleLevel }
        let sourceIndex = min(index * levels.count / Self.barCount, levels.count - 1)
        let raw = levels[sourceIndex]
        return CGFloat(min(max(raw, 0), 1))
    }
}
