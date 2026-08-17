import AppKit
import CoreModels
import PersistenceKit
import ServiceManagement
import SwiftUI

/// Settings panes, v1 subset of FR-11.2: General, Cleanup, Dictionary,
/// History & privacy, About. Hosted in an AppKit window via `WindowManager`
/// (docs/03 §3.4).
@MainActor
struct SettingsView: View {
    @ObservedObject private var appState: AppState
    @ObservedObject private var settings: SettingsStore

    init(appState: AppState) {
        _appState = ObservedObject(wrappedValue: appState)
        _settings = ObservedObject(wrappedValue: appState.settings)
    }

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            CleanupPane(settings: settings)
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            DictionaryPane(database: appState.database)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryPrivacyPane(settings: settings, database: appState.database)
                .tabItem { Label("History & Privacy", systemImage: "clock.arrow.circlepath") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

/// Rows of the push-to-talk dropdown: every binding, plus the recorder entry
/// point (docs/13 §2).
private enum HotkeyPickerSelection: Hashable {
    case spec(HotkeySpec)
    case record
}

@MainActor
private struct GeneralPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var launchAtLogin = false
    @State private var loginItemError: String?
    @State private var globeActionConfigured = false
    @State private var isRecordingHotkey = false

    var body: some View {
        Form {
            Section("Push-to-talk key") {
                Picker("Hold to talk", selection: hotkeySelection) {
                    ForEach(HotkeySpec.presetGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.specs, id: \.self) { spec in
                                Text(spec.label).tag(HotkeyPickerSelection.spec(spec))
                            }
                        }
                    }
                    if !settings.hotkeySpec.isPreset {
                        // The recorded binding needs its own row, or the picker
                        // would have no tag matching the current selection.
                        Section("Custom") {
                            Text(settings.hotkeySpec.label)
                                .tag(HotkeyPickerSelection.spec(settings.hotkeySpec))
                        }
                    }
                    Section {
                        Text("Custom…").tag(HotkeyPickerSelection.record)
                    }
                }
                hotkeyNotes
            }
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Play sounds", isOn: $settings.soundsEnabled)
                Toggle("Show HUD while dictating", isOn: $settings.hudEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            globeActionConfigured = FnKeySetup.globeKeyActionIsConfigured()
        }
        .sheet(isPresented: $isRecordingHotkey) {
            HotkeyRecorderSheet { spec in
                settings.hotkeySpec = spec
                // A custom binding may re-introduce the Globe caveat, or drop it.
                globeActionConfigured = FnKeySetup.globeKeyActionIsConfigured()
            }
        }
    }

    /// "Custom…" is an action, not a value: reading always reports the stored
    /// binding, so picking it opens the recorder and the menu snaps back.
    private var hotkeySelection: Binding<HotkeyPickerSelection> {
        Binding(
            get: { .spec(settings.hotkeySpec) },
            set: { selection in
                switch selection {
                case .spec(let spec): settings.hotkeySpec = spec
                case .record: isRecordingHotkey = true
                }
            }
        )
    }

    @ViewBuilder
    private var hotkeyNotes: some View {
        if settings.hotkeySpec.usesFnKey && globeActionConfigured {
            // docs/03 §3.1: the Globe system action fires at the IOHID layer and
            // cannot be suppressed; the user must set "Press 🌐 key to: Do
            // Nothing" themselves.
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    """
                    The 🌐 key currently triggers a system action (emoji \
                    picker or input switching) that Vocal cannot suppress. \
                    In System Settings → Keyboard, set “Press 🌐 key to” \
                    to “Do Nothing”.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Open Keyboard Settings") {
                    FnKeySetup.openKeyboardSettings()
                }
            }
        }
        ForEach(settings.hotkeySpec.advisories, id: \.self) { advisory in
            HotkeyAdvisoryLabel(advisory: advisory)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Could not update login item: \(error.localizedDescription)"
        }
        // Reflect what the system actually recorded, not what was requested.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Cleanup

@MainActor
private struct CleanupPane: View {
    @ObservedObject var settings: SettingsStore
    @AppStorage("ollamaBaseURL") private var ollamaBaseURL = "http://localhost:11434"

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI cleanup", isOn: $settings.cleanupMasterSwitch)
                Text(
                    """
                    Ships off. When on, cleanup-enabled profiles send text to the \
                    local Ollama model below; if it fails or times out, the plain \
                    transcription is delivered unchanged.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Ollama") {
                TextField("Server URL", text: $ollamaBaseURL)
                TextField("Model", text: $settings.ollamaModel)
            }
            Section("Custom style prompt") {
                // FR-10.1: one global style prompt for all cleanup-enabled
                // profiles (unless a profile opts out).
                TextEditor(text: $settings.stylePrompt)
                    .font(.body)
                    .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictionary

@MainActor
private struct DictionaryPane: View {
    let database: DatabaseStore?
    @State private var entries: [DictionaryEntry] = []
    @State private var spoken = ""
    @State private var written = ""
    @State private var errorText: String?

    var body: some View {
        if database == nil {
            VStack(spacing: 8) {
                Text("Dictionary unavailable")
                    .font(.headline)
                Text("The Vocal database could not be opened; dictionary overrides are disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                List {
                    if entries.isEmpty {
                        Text("No dictionary entries yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.spoken)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text(entry.written)
                                .bold()
                            Spacer()
                            Button {
                                remove(entry)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this entry")
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Heard (spoken form)", text: $spoken)
                    TextField("Should appear (written form)", text: $written)
                    Button("Add") { add() }
                        .disabled(!canAdd)
                }
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
            .onAppear { reload() }
        }
    }

    private var canAdd: Bool {
        let spokenTrimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let writtenTrimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        return !spokenTrimmed.isEmpty && !writtenTrimmed.isEmpty
    }

    private func reload() {
        guard let database else { return }
        do {
            entries = try database.dictionaryEntries()
            errorText = nil
        } catch {
            entries = []
            errorText = "Could not load dictionary: \(error.localizedDescription)"
        }
    }

    private func add() {
        guard let database, canAdd else { return }
        let entry = DictionaryEntry(
            spoken: spoken.trimmingCharacters(in: .whitespacesAndNewlines),
            written: written.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )
        do {
            try database.save(entry)
            spoken = ""
            written = ""
            reload()
        } catch {
            errorText = "Could not save entry: \(error.localizedDescription)"
        }
    }

    private func remove(_ entry: DictionaryEntry) {
        guard let database else { return }
        do {
            try database.deleteDictionaryEntry(id: entry.id)
            reload()
        } catch {
            errorText = "Could not delete entry: \(error.localizedDescription)"
        }
    }
}

// MARK: - History & privacy

@MainActor
private struct HistoryPrivacyPane: View {
    @ObservedObject var settings: SettingsStore
    let database: DatabaseStore?
    @State private var confirmingDeleteAll = false
    @State private var statusText: String?

    var body: some View {
        Form {
            Section("Audio recordings") {
                // -1 = keep forever, 0 = never keep (SettingsStore contract).
                Picker("Keep audio", selection: $settings.audioRetentionDays) {
                    Text("Never").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Forever").tag(-1)
                }
            }
            Section("History") {
                Button("Delete All History…", role: .destructive) {
                    confirmingDeleteAll = true
                }
                .disabled(database == nil)
                if database == nil {
                    Text("The Vocal database could not be opened; history is disabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all history?",
            isPresented: $confirmingDeleteAll
        ) {
            Button("Delete All", role: .destructive) { deleteAllHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every transcript from Vocal's history.")
        }
    }

    private func deleteAllHistory() {
        guard let database else { return }
        do {
            let all = try database.allTranscripts()
            for record in all {
                try database.deleteTranscript(id: record.id)
            }
            statusText = "Deleted \(all.count) transcript\(all.count == 1 ? "" : "s")."
        } catch {
            statusText = "Delete failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - About

@MainActor
private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Vocal")
                .font(.title)
                .bold()
            Text("Version \(Self.versionString)")
                .foregroundStyle(.secondary)
            Text("Personal offline dictation for English and 简体中文. Audio and transcripts stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
