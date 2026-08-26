import AppKit
import AudioPipeline
import CoreModels
import ModelStore
import PersistenceKit
import ServiceManagement
import SwiftUI

/// Settings panes, v1 subset of FR-11.2: General, Profiles, Cleanup,
/// Dictionary, History & privacy, About. Hosted in an AppKit window via
/// `WindowManager` (docs/03 §3.4).
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
            GeneralPane(settings: settings, appState: appState)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesPane(profileStore: appState.profileStore)
                .tabItem { Label("Profiles", systemImage: "person.2") }
            ModelsPane(settings: settings)
                .tabItem { Label("Models", systemImage: "cpu") }
            CleanupPane(settings: settings)
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            DictionaryPane(database: appState.database)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryPrivacyPane(settings: settings, database: appState.database)
                .tabItem { Label("History & Privacy", systemImage: "clock.arrow.circlepath") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Sized for the Profiles master–detail pane; the Form panes are
        // scrollable at any size.
        .frame(width: 680, height: 560)
    }
}

// MARK: - General

@MainActor
private struct GeneralPane: View {
    @ObservedObject var settings: SettingsStore
    let appState: AppState
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Push-to-talk key") {
                // Same control onboarding shows, so the two cannot drift.
                HotkeyPickerView(appState: appState)
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
                Toggle("Show latency after each dictation", isOn: $settings.showTimingsToast)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
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

// MARK: - Models (docs/15 step 15)

/// Settings → Models: the resurrected ModelStore. The primary EN/ZH model is
/// a picker instead of a hardcoded name; the locally managed models
/// (Burmese, VAD) show their real on-disk footprint with a delete that goes
/// through `ModelStore`'s hardened path checks.
@MainActor
private struct ModelsPane: View {
    @ObservedObject var settings: SettingsStore

    /// One locally managed catalog entry's measured state.
    private struct LocalModelRow: Identifiable {
        var spec: ModelSpec
        var state: InstalledState
        var bytes: Int64
        var id: String { spec.id }
    }

    @State private var localRows: [LocalModelRow] = []
    @State private var statusText: String?

    /// WhisperKit-served choices, from the catalog — the pane never invents
    /// model names.
    private var primaryChoices: [ModelSpec] {
        ModelCatalog.builtIn.filter { $0.engine == "whisperkit" && $0.engineModelName != nil }
    }

    var body: some View {
        Form {
            Section("Primary model (English / 中文)") {
                Picker("Model", selection: $settings.whisperKitModel) {
                    ForEach(primaryChoices, id: \.id) { spec in
                        Text("\(spec.displayName) (~\(Self.formatBytes(spec.approximateBytes)))")
                            .tag(spec.engineModelName ?? spec.id)
                    }
                }
                Text(
                    """
                    Applies immediately: the current model is released and the \
                    chosen one loads in the background. A model that has never \
                    been used downloads first (WhisperKit manages its own files).
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("English fast path") {
                Toggle(
                    "Use Parakeet v2 for pinned English",
                    isOn: $settings.parakeetEnglishEnabled
                )
                Text(
                    """
                    Parakeet TDT runs on the Neural Engine at roughly 100× \
                    real time — the docs/15 raw-speed lever. Applies to the \
                    next dictation with the language pinned to English; Auto, \
                    中文, and မြန်မာ keep their engines. First use downloads \
                    ~600 MB (FluidAudio manages its own files).
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Downloaded models") {
                if localRows.isEmpty {
                    Text("No locally managed models are installed yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(localRows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.spec.displayName)
                            Text(Self.stateLabel(row.state, bytes: row.bytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if row.state != .notInstalled {
                            Button("Delete", role: .destructive) {
                                delete(row.spec)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Text(
                    """
                    Deleted models re-download automatically the next time a \
                    dictation needs them.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let statusText {
                Section {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
    }

    /// The catalog entries whose files live inside Vocal's own models tree —
    /// exactly what `ModelStore` can measure and safely delete.
    private var locallyManagedSpecs: [ModelSpec] {
        ModelCatalog.builtIn.filter { $0.engine == "sherpa-onnx" }
    }

    private func reload() {
        guard let root = AppState.modelsDirectory() else { return }
        let specs = locallyManagedSpecs
        Task {
            let store = ModelStore(rootDirectory: root)
            var rows: [LocalModelRow] = []
            for spec in specs {
                let state = await store.installedState(of: spec)
                let bytes = await store.downloadedBytes(of: spec)
                rows.append(LocalModelRow(spec: spec, state: state, bytes: bytes))
            }
            localRows = rows
        }
    }

    private func delete(_ spec: ModelSpec) {
        guard let root = AppState.modelsDirectory() else { return }
        Task {
            let store = ModelStore(rootDirectory: root)
            do {
                try await store.delete(spec)
                statusText = "Deleted \(spec.displayName)."
            } catch {
                statusText = "Could not delete \(spec.displayName): \(error)"
            }
            reload()
        }
    }

    private static func stateLabel(_ state: InstalledState, bytes: Int64) -> String {
        switch state {
        case .notInstalled: return "Not downloaded"
        case .partial: return "Partial download (\(formatBytes(bytes)) on disk)"
        case .installed: return "\(formatBytes(bytes)) on disk"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
            // One SQL statement, deliberately not fetch-decode-delete-each:
            // the list query skips rows this build cannot decode, and
            // enumerating it would silently spare them — breaking the
            // dialog's "permanently removes every transcript" promise.
            let count = try database.deleteAllTranscripts()
            // Retained recordings are transcript data too — "delete every
            // transcript" cannot leave the audio of every transcript behind.
            if let directory = AppState.audioDirectory() {
                AudioArchive.deleteAll(in: directory)
            }
            // Deleting rows only unlinks them: the transcript text stays
            // readable in the file's free pages until it is overwritten.
            // Compacting is what makes "permanently removes" true, and it is
            // only safe to run now that rowids are stable (docs/11 G7).
            try database.vacuum()
            statusText = "Deleted \(count) transcript\(count == 1 ? "" : "s")."
        } catch {
            statusText = "Delete failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - About

@MainActor
private struct AboutPane: View {
    @State private var counters: [(counter: Diagnostics.Counter, count: Int)] = []

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
            Text("Personal offline dictation for English, 简体中文, and မြန်မာ. Audio and transcripts stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            // The Burmese caveat both apps must state identically (docs/11 G13).
            Text(BurmeseSupportNote.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(counters, id: \.counter) { entry in
                        HStack {
                            Text(entry.counter.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(entry.count)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Reset Counters") {
                            Diagnostics.shared.reset()
                            counters = Diagnostics.shared.snapshot()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { counters = Diagnostics.shared.snapshot() }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
