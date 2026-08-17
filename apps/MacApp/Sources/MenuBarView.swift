import AppKit
import CoreModels
import SwiftUI

/// Manual profile pin (FR-8.3). Lives outside SettingsStore because pinning is
/// transient UI state, not a persisted setting; a singleton so the menu and the
/// composition root's press-time profile resolution share one value.
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
    // The composition root's single store, so pin-picker UUIDs always match
    // the resolver's (FR-8.3) and edits from Settings → Profiles show up here
    // live (docs/11 G17).
    @ObservedObject private var profileStore: ProfileStore

    init(appState: AppState) {
        _appState = ObservedObject(wrappedValue: appState)
        _settings = ObservedObject(wrappedValue: appState.settings)
        _pinState = ObservedObject(wrappedValue: PinState.shared)
        _profileStore = ObservedObject(wrappedValue: appState.profileStore)
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
                ForEach(profileStore.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }

            Toggle(isOn: $settings.cleanupMasterSwitch) {
                Text(settings.cleanupMasterSwitch ? "Cleanup: On" : "Cleanup: Off")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            // FR-1.6: Escape throws a take away, but the audio survives for 24
            // hours. Shown only while there is something to recover, so the
            // menu does not carry a permanently dead entry.
            if let candidate = appState.recoverableTake {
                Button("Recover Cancelled Take (\(Self.durationLabel(candidate.durationSeconds)))") {
                    appState.recoverLastCancelledTake()
                }
                .help(
                    "Transcribe the take you cancelled and insert it where you are typing now. Cancelled takes stay recoverable for 24 hours."
                )
            }

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
        // The sidecar can appear or expire while the menu is closed — and a
        // crash leaves one behind with no phase change to notice it.
        .onAppear { appState.refreshRecoverableTake() }
    }

    /// "12s" / "1:24" — enough for the user to tell which take is on offer.
    static func durationLabel(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        guard whole >= 60 else { return "\(whole)s" }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.headline)
                // The hotkey is customizable, so this is the one place that
                // always answers "which key do I hold again?".
                Text("Hold \(settings.hotkeySpec.label) to talk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}
