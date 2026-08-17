import CoreModels
import SwiftUI

/// Settings (docs/02 FR-i parity subset): model warm-up, cleanup master
/// switch, style prompt, profile pick, delivery options.
struct IOSSettingsView: View {
    @ObservedObject var appState: IOSAppState
    @ObservedObject var coordinator: CaptureSessionCoordinator
    @ObservedObject var processor: ImportProcessor
    @State private var isWarming = false
    @State private var warmState: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("On other apps") {
                    NavigationLink {
                        KeyboardSessionView(coordinator: coordinator)
                    } label: {
                        LabeledContent("Keyboard", value: keyboardSummary)
                    }
                    NavigationLink {
                        IOSImportsView(processor: processor)
                    } label: {
                        LabeledContent(
                            "Voice notes",
                            value: coordinator.pendingImportCount == 0
                                ? "None waiting" : "\(coordinator.pendingImportCount) waiting"
                        )
                    }
                }

                Section("Speech model") {
                    Button {
                        warmUp()
                    } label: {
                        if isWarming {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Downloading & loading…")
                            }
                        } else {
                            Text("Warm Up Model")
                        }
                    }
                    .disabled(isWarming)
                    if let warmState {
                        Text(warmState)
                            .font(.callout)
                            .foregroundStyle(warmState.hasPrefix("Ready") ? .green : .red)
                    }
                    Text("Whisper large-v3-turbo (~600 MB), downloaded once, stored on device. English + 中文 + မြန်မာ, fully offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(BurmeseSupportNote.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Profile") {
                    Picker("Active profile", selection: profileBinding) {
                        Text("Default (auto)").tag("")
                        ForEach(appState.profiles) { profile in
                            Text(profile.name).tag(profile.name)
                        }
                    }
                }

                Section {
                    Toggle("AI cleanup", isOn: appState.binding(\.cleanupMasterSwitch))
                    TextField(
                        "Style prompt (applies when cleanup is on)",
                        text: appState.binding(\.stylePrompt),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                } header: {
                    Text("Cleanup")
                } footer: {
                    Text("Off by default. On iPhone, cleanup uses Apple's on-device model when available; the raw transcript is always kept in History.")
                }

                Section("Delivery") {
                    Toggle("Auto-copy to clipboard", isOn: appState.binding(\.autoCopy))
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var keyboardSummary: String {
        guard coordinator.isBridgeAvailable else { return "Unavailable" }
        guard let session = coordinator.session, session.isArmed(at: Date()) else {
            return "Not armed"
        }
        return "Armed · \(KeyboardSessionView.remainingText(session.remaining(at: Date())))"
    }

    private var profileBinding: Binding<String> {
        Binding(
            get: { appState.selectedProfileName },
            set: { appState.selectedProfileName = $0 }
        )
    }

    private func warmUp() {
        isWarming = true
        warmState = nil
        Task {
            do {
                try await appState.warmUp()
                warmState = "Ready — first dictation will be instant."
            } catch {
                warmState = "Download failed — check your connection and retry."
            }
            isWarming = false
        }
    }
}

extension IOSAppState {
    /// Bindings over @AppStorage-backed properties for Form controls.
    func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<IOSAppState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }
}
