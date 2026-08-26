import CoreModels
import SwiftUI

/// Settings (docs/02 FR-i parity subset): model warm-up, cleanup master
/// switch, style prompt, profile pick, delivery options.
struct IOSSettingsView: View {
    @ObservedObject var appState: IOSAppState
    @State private var isWarming = false
    @State private var warmState: String?

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Whisper large-v3-turbo (~600 MB), downloaded once, stored on device. English + 中文, fully offline.")
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

                // Truth pass (docs/14 W16): no cleanup provider is wired on
                // iPhone yet, so no toggle pretends otherwise. The section
                // returns when the on-device provider lands.
                Section("Cleanup") {
                    Text("AI cleanup is not available on iPhone yet — transcripts are delivered as recognized. It arrives with Apple's on-device model in a later update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Delivery") {
                    Toggle("Auto-copy to clipboard", isOn: appState.binding(\.autoCopy))
                }
            }
            .navigationTitle("Settings")
        }
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
