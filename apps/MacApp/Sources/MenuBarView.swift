import AppKit
import CoreModels
import PersistenceKit
import ProfileKit
import SwiftUI

/// Manual profile pin (FR-8.3). Lives outside SettingsStore because pinning is
/// transient UI state, not a persisted setting; a singleton so the menu and the
/// composition root's profile resolution can share it once app-core wires
/// `manualPinProfileID` into `ProfileResolver.resolve` (currently passed nil).
@MainActor
final class PinState: ObservableObject {
    static let shared = PinState()

    /// nil = automatic routing by frontmost app/website.
    @Published var pinnedProfileID: UUID?

    private init() {}
}

/// Content of the `MenuBarExtra(.window)` dropdown (docs/03 §3.4). Status,
/// quick toggles, and entry points to the AppKit-managed windows; all window
/// opening goes through `WindowManager` because SwiftUI `openSettings` is
/// broken from menu-bar apps (docs/03 §3.4).
@MainActor
struct MenuBarView: View {
    @ObservedObject private var appState: AppState
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var pinState: PinState
    @State private var profiles: [Profile] = []

    init(appState: AppState) {
        _appState = ObservedObject(wrappedValue: appState)
        _settings = ObservedObject(wrappedValue: appState.settings)
        _pinState = ObservedObject(wrappedValue: PinState.shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Language", selection: languageSelection) {
                    Text("Auto").tag(LanguageMode.auto)
                    // Driven by Language.allCases so adding a language is a
                    // CoreModels change only (docs/04 §2).
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.shortLabel).tag(LanguageMode.pinned(language))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Picker("Profile", selection: $pinState.pinnedProfileID) {
                Text("Auto (by app)").tag(Optional<UUID>.none)
                ForEach(profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }

            Toggle(isOn: $settings.cleanupMasterSwitch) {
                Text(settings.cleanupMasterSwitch ? "Cleanup: On" : "Cleanup: Off")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            Button("Open History") {
                WindowManager.shared.showHistory(appState: appState)
            }
            Button("Settings…") {
                WindowManager.shared.showSettings(appState: appState)
            }

            Divider()

            Button("Quit Vocal") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { loadProfiles() }
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.headline)
                if !appState.hudState.profileName.isEmpty {
                    Text("Profile: \(appState.hudState.profileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        switch appState.hudState.mode {
        case .hidden: return "Idle"
        case .listening: return "Listening…"
        case .processing: return "Processing…"
        case .error(let message): return message
        case .notice(let message): return message
        }
    }

    private var statusSymbol: String {
        switch appState.hudState.mode {
        case .hidden: return "mic"
        case .listening: return "mic.fill"
        case .processing: return "waveform"
        case .error: return "mic.slash"
        case .notice: return "info.circle"
        }
    }

    // MARK: - Language quick toggle

    /// `LanguageMode` is itself Hashable, so it doubles as the picker tag —
    /// no parallel enum to keep in sync with the language list.
    private var languageSelection: Binding<LanguageMode> {
        Binding(
            get: { settings.languageMode },
            set: { settings.languageMode = $0 }
        )
    }

    // MARK: - Profiles

    private func loadProfiles() {
        // The composition root builds the profile list once; using the same
        // instances keeps pin-picker UUIDs aligned with the resolver's
        // (a fresh BuiltInProfiles.makeAll() here would mint different IDs
        // and make pinning a silent no-op — FR-8.3).
        profiles = appState.profiles
    }
}
