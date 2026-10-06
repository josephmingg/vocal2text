import AppKit
import ASRKit
import AudioPipeline
import BenchKit
import SwiftUI

/// Recording and scoring state for the Speed Check pane (docs/17 G0).
@MainActor
final class SpeedCheckModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case recording(passage: Int)
        case decoding(passage: Int)
        case finished
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var measurements: [SpeedCheck.Measurement] = []
    @Published private(set) var problems: [String] = []
    @Published var includeParakeet = true

    /// Its own sidecar prefix: a test passage must never be offered back by
    /// "Recover" as if it were a dictation (docs/17 §11).
    private let microphone = MicrophoneCapture(sidecarPrefix: RecoveryFileReaper.measurementFilePrefix)
    private var session: MicrophoneSession?
    private var nextPassage = 0
    /// Bumped by Start Over: a decode still running for the previous run
    /// must not write its results into the new one.
    private var run = 0
    /// The microphone is opening (the first time, behind the permission
    /// prompt); a cancel that lands meanwhile is honoured once it opens.
    private var isStarting = false
    private var cancelWhileStarting = false

    var isBusy: Bool {
        switch stage {
        case .recording, .decoding: true
        case .idle, .finished: isStarting
        }
    }

    var currentPassage: Int? {
        switch stage {
        case .recording(let passage), .decoding(let passage): passage
        case .idle: nextPassage < SpeedCheck.passages.count ? nextPassage : nil
        case .finished: nil
        }
    }

    var summaries: [SpeedCheck.Summary] { SpeedCheck.summarize(measurements) }

    func reset() {
        guard !isBusy else { return }
        run += 1
        measurements = []
        problems = []
        nextPassage = 0
        stage = .idle
    }

    func startRecording() async {
        guard case .idle = stage, !isStarting, nextPassage < SpeedCheck.passages.count else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let started = try await microphone.start()
            if cancelWhileStarting {
                // The pane closed or Cancel was pressed while the mic opened.
                cancelWhileStarting = false
                await started.cancel()
                RecoveryStore.discard(at: started.recoveryFileURL)
                return
            }
            session = started
            stage = .recording(passage: nextPassage)
        } catch {
            cancelWhileStarting = false
            problems.append("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    func stopRecording(appState: AppState) async {
        guard case .recording(let passage) = stage, let session else { return }
        self.session = nil
        let thisRun = run
        let audio = await session.finish()
        guard audio.durationSeconds >= 2 else {
            problems.append("Passage \(passage + 1) was too short — read the whole passage, then stop.")
            stage = .idle
            return
        }
        stage = .decoding(passage: passage)
        let outcome = await appState.speedCheckDecode(
            audio,
            passageIndex: passage,
            includeParakeet: includeParakeet,
            warmUp: passage == 0
        )
        guard thisRun == run else { return }
        measurements += outcome.measurements
        problems += outcome.failures
        nextPassage = passage + 1
        stage = nextPassage < SpeedCheck.passages.count ? .idle : .finished
    }

    func cancelRecording() async {
        if isStarting {
            cancelWhileStarting = true
            return
        }
        guard case .recording = stage, let session else { return }
        self.session = nil
        await session.cancel()
        // A cancelled capture keeps its crash sidecar for "Recover" (FR-1.6);
        // a Speed Check passage is not a dictation and must not be offered
        // back — the pane promises recordings are discarded.
        RecoveryStore.discard(at: session.recoveryFileURL)
        stage = .idle
    }

    func report() -> String {
        SpeedCheck.markdown(measurements: measurements, machine: Self.machineName(), date: Date())
    }

    /// Hardware model and OS — never the user-chosen computer name, which is
    /// often a person's name.
    static func machineName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = "Mac"
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
                model = String(cString: buffer)
            }
        }
        return "\(model), \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// Settings → Speed Check: read three short passages; Vocal decodes the
/// same recording with Whisper and Parakeet and shows your own numbers.
@MainActor
struct SpeedCheckPane: View {
    let appState: AppState
    @StateObject private var model = SpeedCheckModel()
    @State private var savedNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                """
                Measures this Mac with your voice: read each passage once, \
                and Vocal decodes the same recording with every engine. \
                Nothing leaves this Mac, and recordings are discarded.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Include Parakeet (downloads ~600 MB the first time)", isOn: $model.includeParakeet)
                .disabled(model.stage != .idle || !model.measurements.isEmpty)

            passageBox

            if !model.measurements.isEmpty {
                resultsTable
            }
            ForEach(model.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Start Over") { model.reset() }
                    .disabled(model.isBusy || (model.measurements.isEmpty && model.problems.isEmpty))
                Spacer()
                if let savedNote {
                    Text(savedNote).font(.caption).foregroundStyle(.secondary)
                }
                Button("Copy Report") { copyReport() }
                    .disabled(model.measurements.isEmpty)
                Button("Save Report…") { saveReport() }
                    .disabled(model.measurements.isEmpty)
            }
        }
        .padding(16)
        // Closing Settings mid-passage must not leave the microphone open.
        // Switching tabs removes the pane (onDisappear); closing the window
        // only orders it out — Settings is kept alive — so that needs the
        // window's own close notification.
        .onDisappear {
            Task { await model.cancelRecording() }
        }
        .background(WindowCloseObserver { Task { await model.cancelRecording() } })
    }

    @ViewBuilder
    private var passageBox: some View {
        switch model.stage {
        case .finished:
            Label("All three passages done.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .decoding(let passage):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Decoding passage \(passage + 1) with each engine…")
            }
        case .idle, .recording:
            if let passage = model.currentPassage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Passage \(passage + 1) of \(SpeedCheck.passages.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(SpeedCheck.passages[passage])
                        .font(.title3)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                    HStack {
                        if case .recording = model.stage {
                            Button("Stop") {
                                Task { await model.stopRecording(appState: appState) }
                            }
                            .keyboardShortcut(.defaultAction)
                            Button("Cancel") { Task { await model.cancelRecording() } }
                            Label("Recording — read the passage at your normal pace", systemImage: "mic.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Button("Record Passage \(passage + 1)") {
                                Task { await model.startRecording() }
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
        }
    }

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Engine").bold()
                    Text("Release→text (p50)").bold()
                    Text("Speed").bold()
                    Text("Word errors").bold()
                }
                ForEach(model.summaries, id: \.engine) { summary in
                    GridRow {
                        Text(summary.engine)
                        Text("\(Int((summary.releaseToTextP50 * 1000).rounded())) ms")
                            .monospacedDigit()
                        Text(String(format: "%.0f× real time", summary.realTimeFactor))
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", summary.wordErrorRate * 100))
                            .monospacedDigit()
                    }
                }
            }
            .font(.callout)
            Text(SpeedCheck.recommendation(model.summaries))
                .font(.callout.weight(.medium))
        }
    }

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.report(), forType: .string)
        savedNote = "Copied"
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "M0-results.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.report().write(to: url, atomically: true, encoding: .utf8)
            savedNote = "Saved"
        } catch {
            savedNote = "Save failed: \(error.localizedDescription)"
        }
    }
}

/// Calls `onClose` when the window hosting it closes. Settings windows are
/// retained and merely ordered out on close, so SwiftUI's `onDisappear`
/// does not fire for them.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onClose = onClose
    }

    final class ObservingView: NSView {
        var onClose: (() -> Void)?

        // Selector-based: NotificationCenter drops the registration when the
        // view deallocates, so no token or deinit bookkeeping is needed.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.willCloseNotification, object: nil
            )
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window
            )
        }

        @objc private func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }
}
