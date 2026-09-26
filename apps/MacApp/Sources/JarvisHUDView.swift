import SwiftUI

/// Cosmetic skin for the recording HUD. Chosen in Settings → General; it only
/// changes what the panel draws, never the dictation path.
enum HUDStyle: String, CaseIterable {
    case jarvis
    case classic

    var displayName: String {
        switch self {
        case .jarvis: return "Arc Reactor"
        case .classic: return "Classic"
        }
    }
}

/// "Arc Reactor" HUD: a spinning reactor orb that breathes with your voice,
/// a telemetry strip and a monospaced transcript line on dark glass.
///
/// Performance budget (it must never cost dictation latency):
/// - Everything moving is drawn by three small `Canvas` views — no blurs, no
///   shadows, no per-element views — driven by one `TimelineView` capped at
///   30 fps.
/// - The timeline exists only while the panel shows something: `.hidden`
///   renders `EmptyView`, so an idle app draws nothing at all.
/// - Reduce Motion drops the timeline to 1 Hz and freezes every rotation.
struct JarvisHUDView: View {
    let state: HUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state.mode == .hidden {
                EmptyView()
            } else if reduceMotion {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    hud(at: context.date)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    hud(at: context.date)
                }
            }
        }
        .frame(
            width: HUDPanelController.panelSize.width,
            height: HUDPanelController.panelSize.height
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Frame

    private func hud(at date: Date) -> some View {
        let look = Look(mode: state.mode)
        let time = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let level = currentLevel(time: time)
        return ZStack {
            JarvisChassis(accent: look.accent, time: time)
            HStack(spacing: 12) {
                ArcReactor(
                    accent: look.accent,
                    time: time,
                    spin: look.spin,
                    level: level,
                    levels: reduceMotion ? [] : state.levels,
                    showsSpectrum: look.isListening
                )
                .frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 5) {
                    header(look: look, date: date)
                    TelemetryStrip(
                        accent: look.accent,
                        time: time,
                        levels: reduceMotion ? [] : state.levels,
                        isListening: look.isListening
                    )
                    .frame(height: 18)
                    transcriptLine(look: look, time: time)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.title.capitalized)
    }

    // MARK: - Rows

    private func header(look: Look, date: Date) -> some View {
        HStack(spacing: 6) {
            Text(look.title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(look.accent)
            if case .listening(let startedAt) = state.mode {
                Text(Self.timer(from: startedAt, to: date, tenths: !reduceMotion))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            Spacer(minLength: 4)
            if !state.profileName.isEmpty {
                chip(state.profileName.uppercased(), accent: look.accent)
            }
            if !state.languageLabel.isEmpty {
                chip(state.languageLabel.uppercased(), accent: look.accent)
            }
            if state.isRemoteCleanup {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(look.accent.opacity(0.8))
                    .help("Cleanup uses a remote provider")
            }
        }
    }

    private func chip(_ text: String, accent: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .tracking(1)
            .lineLimit(1)
            .foregroundStyle(accent.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 0.75)
            )
    }

    private func transcriptLine(look: Look, time: TimeInterval) -> some View {
        let caretOn = reduceMotion || sin(time * 5.5) > -0.2
        return HStack(spacing: 1) {
            Text(lineText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.head)
            if look.isListening {
                Text("▍")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(look.accent)
                    .opacity(caretOn ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lineText: String {
        switch state.mode {
        case .error(let message), .notice(let message):
            return message
        default:
            if !state.partialText.isEmpty { return state.partialText }
            if case .listening = state.mode { return "> awaiting voice input" }
            return ""
        }
    }

    // MARK: - Helpers

    /// Latest mic level; before the first chunk (and between words) the core
    /// keeps a slow idle breath so it never looks dead.
    private func currentLevel(time: TimeInterval) -> Double {
        let idle = 0.1 + 0.05 * sin(time * 2.2)
        guard !reduceMotion, let last = state.levels.last else { return idle }
        return max(idle, min(Double(last), 1))
    }

    private static func timer(from start: Date, to now: Date, tenths: Bool) -> String {
        let elapsed = max(0, now.timeIntervalSince(start))
        let whole = Int(elapsed)
        if tenths {
            let tenth = Int((elapsed - Double(whole)) * 10)
            return String(format: "%02d:%02d.%d", whole / 60, whole % 60, tenth)
        }
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    /// Per-mode title, colour and reactor speed.
    private struct Look {
        let title: String
        let accent: Color
        let spin: Double
        let isListening: Bool

        static let cyan = Color(red: 0.25, green: 0.88, blue: 1.0)
        static let amber = Color(red: 1.0, green: 0.72, blue: 0.28)
        static let green = Color(red: 0.3, green: 1.0, blue: 0.68)
        static let red = Color(red: 1.0, green: 0.3, blue: 0.37)

        init(mode: HUDState.Mode) {
            switch mode {
            case .listening:
                self.init("LISTENING", Self.cyan, spin: 1, listening: true)
            case .processing(.transcribing):
                self.init("TRANSCRIBING", Self.cyan, spin: 2.6, listening: false)
            case .processing(.cleaning):
                self.init("REFINING", Self.amber, spin: 2.2, listening: false)
            case .processing(.delivering):
                self.init("INSERTED", Self.green, spin: 0.4, listening: false)
            case .error:
                self.init("ALERT", Self.red, spin: 0.25, listening: false)
            case .notice, .hidden:
                self.init("NOTICE", Self.cyan, spin: 0.5, listening: false)
            }
        }

        private init(_ title: String, _ accent: Color, spin: Double, listening: Bool) {
            self.title = title
            self.accent = accent
            self.spin = spin
            self.isListening = listening
        }
    }
}

// MARK: - Chassis

/// Dark glass plate with scanlines, targeting-corner brackets and a light
/// sweep along the top edge.
private struct JarvisChassis: View {
    let accent: Color
    let time: TimeInterval

    private static let radius: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.01, green: 0.04, blue: 0.08).opacity(0.9),
                        Color(red: 0.02, green: 0.08, blue: 0.13).opacity(0.82),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            Canvas { context, size in
                drawScanlines(in: &context, size: size)
                drawSweep(in: &context, size: size)
                drawBrackets(in: &context, size: size)
            }
            shape.strokeBorder(accent.opacity(0.3), lineWidth: 0.75)
        }
        .clipShape(shape)
    }

    private func drawScanlines(in context: inout GraphicsContext, size: CGSize) {
        var lines = Path()
        var y: CGFloat = 1.5
        while y < size.height {
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
            y += 3
        }
        context.stroke(lines, with: .color(accent.opacity(0.04)), lineWidth: 0.5)
    }

    private func drawSweep(in context: inout GraphicsContext, size: CGSize) {
        let span: CGFloat = 90
        let phase = CGFloat((time * 0.35).truncatingRemainder(dividingBy: 1))
        let x = -span + phase * (size.width + span * 2)
        let rect = CGRect(x: x - span / 2, y: 0, width: span, height: 1.2)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [accent.opacity(0), accent.opacity(0.9), accent.opacity(0)]),
                startPoint: CGPoint(x: rect.minX, y: 0),
                endPoint: CGPoint(x: rect.maxX, y: 0)
            )
        )
    }

    private func drawBrackets(in context: inout GraphicsContext, size: CGSize) {
        let arm: CGFloat = 10
        let inset: CGFloat = 5
        let minX = inset, maxX = size.width - inset
        let minY = inset, maxY = size.height - inset
        var path = Path()
        for (x, y, dx, dy) in [
            (minX, minY, arm, arm), (maxX, minY, -arm, arm),
            (minX, maxY, arm, -arm), (maxX, maxY, -arm, -arm),
        ] {
            path.move(to: CGPoint(x: x + dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy))
        }
        context.stroke(
            path,
            with: .color(accent.opacity(0.75)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .square)
        )
    }
}

// MARK: - Arc reactor

/// The orb: tick ring, voice-reactive radial spectrum, two counter-rotating
/// arc rings and a glowing core that swells with the mic level.
private struct ArcReactor: View {
    let accent: Color
    let time: TimeInterval
    let spin: Double
    let level: Double
    let levels: [Float]
    let showsSpectrum: Bool

    private static let spokeCount = 48

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 1
            drawHalo(in: &context, center: center, radius: radius)
            drawTicks(in: &context, center: center, radius: radius)
            if showsSpectrum {
                drawSpectrum(in: &context, center: center, radius: radius)
            } else {
                drawPulseRing(in: &context, center: center, radius: radius)
            }
            drawArcs(in: &context, center: center, radius: radius * 0.8,
                     count: 3, sweep: 70, rotation: time * 1.1 * spin, width: 2, opacity: 0.9)
            drawArcs(in: &context, center: center, radius: radius * 0.44,
                     count: 2, sweep: 110, rotation: -time * 1.7 * spin, width: 1.5, opacity: 0.75)
            drawCore(in: &context, center: center, radius: radius)
        }
    }

    private func drawHalo(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let glow = 0.12 + 0.3 * level
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [accent.opacity(glow), accent.opacity(0)]),
                center: center, startRadius: radius * 0.2, endRadius: radius
            )
        )
    }

    private func drawTicks(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        var ticks = Path()
        let rotation = time * 0.3 * spin
        for index in 0..<60 {
            let angle = Double(index) / 60 * 2 * .pi + rotation
            let length: CGFloat = index % 5 == 0 ? 4 : 2
            ticks.move(to: point(center, radius, angle))
            ticks.addLine(to: point(center, radius - length, angle))
        }
        context.stroke(ticks, with: .color(accent.opacity(0.55)), lineWidth: 0.8)
    }

    /// 48 spokes mirrored left/right so the orb stays symmetric while the
    /// level history scrolls through it.
    private func drawSpectrum(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let inner = radius * 0.56
        let reach = radius * 0.3
        let half = Self.spokeCount / 2
        var spokes = Path()
        for index in 0..<Self.spokeCount {
            let mirrored = index < half ? index : Self.spokeCount - 1 - index
            let value = spokeLevel(mirrored, of: half)
            let angle = Double(index) / Double(Self.spokeCount) * 2 * .pi - .pi / 2 - time * 0.15
            spokes.move(to: point(center, inner, angle))
            spokes.addLine(to: point(center, inner + max(1.5, reach * value), angle))
        }
        context.stroke(
            spokes,
            with: .color(accent.opacity(0.95)),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
        )
    }

    private func spokeLevel(_ index: Int, of count: Int) -> CGFloat {
        guard !levels.isEmpty else { return 0.08 }
        let source = min(index * levels.count / count, levels.count - 1)
        return CGFloat(min(max(levels[source], 0), 1))
    }

    /// While thinking, a ring of dots chases itself instead of the spectrum.
    private func drawPulseRing(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let ringRadius = radius * 0.64
        for index in 0..<24 {
            let angle = Double(index) / 24 * 2 * .pi - .pi / 2
            let wave = (sin(time * 3 * spin - Double(index) * 0.5) + 1) / 2
            let dot = CGFloat(1 + 1.4 * wave)
            let spot = point(center, ringRadius, angle)
            context.fill(
                Path(ellipseIn: CGRect(x: spot.x - dot, y: spot.y - dot, width: dot * 2, height: dot * 2)),
                with: .color(accent.opacity(0.25 + 0.7 * wave))
            )
        }
    }

    private func drawArcs(
        in context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
        count: Int, sweep: Double, rotation: Double, width: CGFloat, opacity: Double
    ) {
        var arcs = Path()
        let step = 360.0 / Double(count)
        let offset = rotation * 180 / .pi
        for index in 0..<count {
            let start = offset + Double(index) * step
            arcs.addArc(center: center, radius: radius,
                        startAngle: .degrees(start), endAngle: .degrees(start + sweep),
                        clockwise: false)
            arcs.move(to: point(center, radius, (start + step) * .pi / 180))
        }
        context.stroke(
            arcs,
            with: .color(accent.opacity(opacity)),
            style: StrokeStyle(lineWidth: width, lineCap: .round)
        )
    }

    private func drawCore(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let core = radius * CGFloat(0.2 + 0.14 * level)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - core * 1.8, y: center.y - core * 1.8,
                                   width: core * 3.6, height: core * 3.6)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.95), accent.opacity(0.8), accent.opacity(0)]),
                center: center, startRadius: 0, endRadius: core * 1.8
            )
        )
        // Tri-beam in the core, a nod to the Mark II reactor.
        var beams = Path()
        for index in 0..<3 {
            let angle = Double(index) / 3 * 2 * .pi - .pi / 2 + time * 0.6 * spin
            beams.move(to: point(center, core * 0.35, angle))
            beams.addLine(to: point(center, radius * 0.36, angle))
        }
        context.stroke(beams, with: .color(Color.white.opacity(0.45)), lineWidth: 1)
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }
}

// MARK: - Telemetry strip

/// Mirrored level bars with a scanning light while listening; a travelling
/// "data stream" of blocks while the take is being processed.
private struct TelemetryStrip: View {
    let accent: Color
    let time: TimeInterval
    let levels: [Float]
    let isListening: Bool

    private static let barCount = 40

    var body: some View {
        Canvas { context, size in
            drawBaseline(in: &context, size: size)
            if isListening {
                drawBars(in: &context, size: size)
            } else {
                drawStream(in: &context, size: size)
            }
            drawScan(in: &context, size: size)
        }
    }

    private func drawBaseline(in context: inout GraphicsContext, size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height / 2))
        line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(line, with: .color(accent.opacity(0.18)), lineWidth: 0.5)
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let count = Self.barCount
        let gap: CGFloat = 2
        let width = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
        let midY = size.height / 2
        for index in 0..<count {
            let value = level(at: index, of: count)
            let height = max(1.2, value * size.height)
            let rect = CGRect(x: CGFloat(index) * (width + gap), y: midY - height / 2,
                              width: width, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: width / 2),
                with: .color(accent.opacity(0.35 + 0.65 * Double(value)))
            )
        }
    }

    private func level(at index: Int, of count: Int) -> CGFloat {
        guard !levels.isEmpty else { return 0.06 }
        let source = min(index * levels.count / count, levels.count - 1)
        return CGFloat(min(max(levels[source], 0), 1))
    }

    private func drawStream(in context: inout GraphicsContext, size: CGSize) {
        let count = 28
        let gap: CGFloat = 3
        let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let height: CGFloat = 4
        for index in 0..<count {
            let wave = (sin(time * 7 - Double(index) * 0.45) + 1) / 2
            let rect = CGRect(x: CGFloat(index) * (width + gap), y: (size.height - height) / 2,
                              width: width, height: height)
            context.fill(Path(rect), with: .color(accent.opacity(0.12 + 0.8 * wave * wave)))
        }
    }

    private func drawScan(in context: inout GraphicsContext, size: CGSize) {
        let phase = CGFloat((time * 0.8).truncatingRemainder(dividingBy: 1))
        let x = phase * size.width
        let band = CGRect(x: x - 14, y: 0, width: 28, height: size.height)
        context.fill(
            Path(band),
            with: .linearGradient(
                Gradient(colors: [accent.opacity(0), accent.opacity(0.22), accent.opacity(0)]),
                startPoint: CGPoint(x: band.minX, y: 0),
                endPoint: CGPoint(x: band.maxX, y: 0)
            )
        )
    }
}
