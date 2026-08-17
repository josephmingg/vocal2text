import CoreModels
import SwiftUI

/// The main dictation screen (docs/02 FR-i1.1): big push-to-talk button —
/// hold to dictate, or tap to toggle — with the result card offering
/// Copy/Share (mode D1 delivery).
private struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

struct DictateView: View {
    @ObservedObject var appState: IOSAppState
    @State private var isToggledOn = false
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusHeader
                Spacer()
                resultCard
                Spacer()
                micButton
                controlsRow
            }
            .padding()
            .navigationTitle("Vocal")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(text: item.text)
        }
        .onAppear {
            // Action Button / Shortcuts entry (StartDictationIntent) arms this
            // flag so opening the app drops straight into listening.
            if UserDefaults.standard.bool(forKey: "pendingAutoStart") {
                UserDefaults.standard.set(false, forKey: "pendingAutoStart")
                appState.startDictation()
            }
        }
    }

    // MARK: - Pieces

    private var statusHeader: some View {
        VStack(spacing: 4) {
            switch appState.display.mode {
            case .idle:
                Text("Hold the mic and speak").foregroundStyle(.secondary)
            case .listening(let startedAt):
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Int(max(0, context.date.timeIntervalSince(startedAt)))
                    Label(
                        String(format: "Listening… %d:%02d", elapsed / 60, elapsed % 60),
                        systemImage: "waveform"
                    )
                    .foregroundStyle(.red)
                }
            case .processing:
                Label("Transcribing…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            case .result:
                Label(
                    appState.autoCopy ? "Copied to clipboard" : "Done",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if !appState.display.profileName.isEmpty {
                Text("Profile: \(appState.display.profileName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.headline)
    }

    @ViewBuilder
    private var resultCard: some View {
        if case .result(let text) = appState.display.mode {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                HStack {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        shareItem = ShareItem(text: text)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button(role: .destructive) {
                        appState.display.mode = .idle
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var micButton: some View {
        Circle()
            .fill(isRecording ? Color.red : Color.accentColor)
            .frame(width: 96, height: 96)
            .overlay {
                Image(systemName: isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isRecording ? 1.08 : 1.0)
            .animation(.spring(duration: 0.25), value: isRecording)
            .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
            // Hold-to-talk: press starts, release stops (FR-i1.1). A quick tap
            // still transcribes if speech was captured (FR-1.5 heuristic).
            .onLongPressGesture(
                minimumDuration: .infinity,
                pressing: { pressing in
                    if pressing {
                        guard !isToggledOn else { return }
                        appState.startDictation()
                    } else {
                        guard !isToggledOn else { return }
                        appState.stopDictation()
                    }
                },
                perform: {}
            )
    }

    private var controlsRow: some View {
        HStack {
            // Language quick pin (FR-i1.1 parity with the Mac menu bar).
            Picker("Language", selection: languageBinding) {
                Text("Auto").tag("auto")
                // Driven by Language.allCases (docs/04 §2).
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.shortLabel).tag(language.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            Spacer()

            Toggle(isOn: $isToggledOn) {
                Text("Hands-free")
            }
            .toggleStyle(.button)
            .onChange(of: isToggledOn) { _, on in
                if on {
                    appState.startDictation()
                } else {
                    appState.stopDictation()
                }
            }
        }
        .font(.callout)
    }

    private var isRecording: Bool {
        if case .listening = appState.display.mode { return true }
        return false
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { appState.languageModeRaw },
            set: { appState.languageModeRaw = $0 }
        )
    }
}

// MARK: - Share sheet bridge

private struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
