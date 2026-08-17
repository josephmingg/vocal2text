import AppKit
import ApplicationServices
import CoreModels
import SwiftUI

/// Rows of the push-to-talk dropdown: every binding, plus the recorder entry
/// point (docs/13 §2).
///
/// Tagged by `kind`, not by the whole spec: `isPreset` matches on kind alone, so
/// tagging by a value that also carries the stored label would leave the picker
/// with no matching row — and a blank selection — the day a keycap name is
/// reworded.
private enum HotkeyPickerSelection: Hashable {
    case binding(HotkeySpec.Kind)
    case record
}

/// The whole push-to-talk key control: dropdown, caveats, recorder, and a live
/// "press it now" test.
///
/// Shared by Settings → General and by onboarding, so the two can never drift
/// apart — onboarding used to leave the user with no idea which key to hold
/// (docs/13 §2).
@MainActor
struct HotkeyPickerView: View {

    private enum TestPhase: Equatable {
        case idle
        case listening
        case seen(String)
        case timedOut(String)
    }

    @ObservedObject private var appState: AppState
    @ObservedObject private var settings: SettingsStore

    @State private var globeActionConfigured = false
    @State private var hotkeyIsArmed = true
    @State private var isRecordingHotkey = false
    @State private var testPhase: TestPhase = .idle
    @State private var testTimeout: Task<Void, Never>?

    /// The tap arms a beat after Accessibility is granted (`AppDelegate` retries
    /// on a timer), and the grant itself arrives with no notification — so poll
    /// while this control is on screen rather than stranding the user on a stale
    /// "inactive" warning.
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(appState: AppState) {
        _appState = ObservedObject(wrappedValue: appState)
        _settings = ObservedObject(wrappedValue: appState.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Hold to talk", selection: hotkeySelection) {
                ForEach(HotkeySpec.presetGroups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.specs, id: \.self) { spec in
                            Text(spec.label).tag(HotkeyPickerSelection.binding(spec.kind))
                        }
                    }
                }
                if !settings.hotkeySpec.isPreset {
                    // The recorded binding needs its own row, or the picker
                    // would have no tag matching the current selection.
                    Section("Your shortcut") {
                        Text(settings.hotkeySpec.label)
                            .tag(HotkeyPickerSelection.binding(settings.hotkeySpec.kind))
                    }
                }
                Section {
                    Text("Record New Shortcut…").tag(HotkeyPickerSelection.record)
                }
            }
            .pickerStyle(.menu)

            tester
            notes
        }
        .onAppear {
            globeActionConfigured = FnKeySetup.globeKeyActionIsConfigured()
            hotkeyIsArmed = appState.hotkeyMonitor?.isArmed ?? true
        }
        .onDisappear { endTest(.idle) }
        .onReceive(recheck) { _ in
            hotkeyIsArmed = appState.hotkeyMonitor?.isArmed ?? true
        }
        .onChange(of: appState.hotkeyPressCount) { _, _ in
            guard testPhase == .listening else { return }
            endTest(.seen(settings.hotkeySpec.label))
        }
        .onChange(of: settings.hotkeySpec) { _, _ in
            // A new key invalidates a previous ✓, and may add or drop the Globe
            // caveat.
            endTest(.idle)
            globeActionConfigured = FnKeySetup.globeKeyActionIsConfigured()
            hotkeyIsArmed = appState.hotkeyMonitor?.isArmed ?? true
        }
        .sheet(isPresented: $isRecordingHotkey) {
            HotkeyRecorderSheet(
                currentBinding: settings.hotkeySpec,
                hotkeyMonitor: appState.hotkeyMonitor
            ) { spec in
                settings.hotkeySpec = spec
            }
        }
    }

    /// "Record New Shortcut…" is an action, not a value: reading always reports
    /// the stored binding, so picking it opens the recorder and the menu snaps
    /// back.
    private var hotkeySelection: Binding<HotkeyPickerSelection> {
        Binding(
            get: { .binding(settings.hotkeySpec.kind) },
            set: { selection in
                switch selection {
                case .binding(let kind): settings.hotkeySpec = HotkeySpec(kind: kind)
                case .record: isRecordingHotkey = true
                }
            }
        )
    }

    // MARK: - Live test

    @ViewBuilder
    private var tester: some View {
        switch testPhase {
        case .idle:
            Button("Test Your Key") { beginTest() }
                .controlSize(.small)
                .disabled(!hotkeyIsArmed)
        case .listening:
            Label(
                "Press \(settings.hotkeySpec.label) now — this won't record anything.",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .seen(let label):
            Label("Vocal saw \(label) — you're set.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .timedOut(let label):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Didn't see \(label). Some external keyboards handle keys in firmware, "
                        + "and F1–F12 need “standard function keys” turned on.",
                    systemImage: "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Try Again") { beginTest() }
                    .controlSize(.small)
            }
        }
    }

    private func beginTest() {
        appState.beginHotkeyTest()
        testPhase = .listening
        let label = settings.hotkeySpec.label
        testTimeout?.cancel()
        testTimeout = Task { [label] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            endTest(.timedOut(label))
        }
    }

    private func endTest(_ phase: TestPhase) {
        testTimeout?.cancel()
        testTimeout = nil
        appState.endHotkeyTest()
        testPhase = phase
    }

    // MARK: - Caveats

    @ViewBuilder
    private var notes: some View {
        if !hotkeyIsArmed {
            // The single most likely support question: the key does nothing.
            // Answer it here instead of leaving the user to guess.
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Hotkey inactive — Vocal needs Accessibility access to listen for it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.red)
                Button("Request Accessibility Access") {
                    // Same prompt onboarding uses; the header's option key is a
                    // mutable global Swift 6 rejects, so the literal is used.
                    _ = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    )
                }
                .controlSize(.small)
            }
        }
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
                .controlSize(.small)
            }
        }
        ForEach(settings.hotkeySpec.advisories, id: \.self) { advisory in
            HotkeyAdvisoryLabel(advisory: advisory)
        }
    }
}
