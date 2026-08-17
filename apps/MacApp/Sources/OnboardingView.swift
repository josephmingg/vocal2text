import AppKit
import ApplicationServices
import AVFoundation
import Combine
import SwiftUI

/// First-run onboarding, pragmatic v1 subset of FR-11.1:
/// welcome → microphone → Accessibility → Fn setup (only when needed) →
/// model warm-up → done. `AppDelegate` presents this via `WindowManager`
/// while the "onboardingComplete" UserDefaults key is false.
@MainActor
struct OnboardingView: View {
    private enum Step: Equatable {
        case welcome
        case microphone
        case accessibility
        case fnSetup
        case modelDownload
        case done
    }

    private let appState: AppState
    private let onFinish: @MainActor () -> Void

    @State private var steps: [Step] = []
    @State private var stepIndex = 0

    init(appState: AppState, onFinish: @escaping @MainActor () -> Void) {
        self.appState = appState
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if stepIndex > 0 && currentStep != .done {
                    Button("Back") { stepIndex -= 1 }
                }
                Spacer()
                Text("Step \(stepIndex + 1) of \(max(steps.count, 1))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                primaryButton
            }
        }
        .padding(24)
        .frame(width: 520, height: 440)
        .onAppear { buildSteps() }
    }

    // MARK: - Flow

    private var currentStep: Step {
        guard steps.indices.contains(stepIndex) else { return .welcome }
        return steps[stepIndex]
    }

    private func buildSteps() {
        guard steps.isEmpty else { return }
        var built: [Step] = [.welcome, .microphone, .accessibility]
        // Fn coexistence page only when the chosen hotkey is Fn AND the Globe
        // key still has a system action bound (docs/03 §3.1).
        if appState.settings.hotkeyChoice == .fnKey && FnKeySetup.globeKeyActionIsConfigured() {
            built.append(.fnSetup)
        }
        built.append(.modelDownload)
        built.append(.done)
        steps = built
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome: WelcomeStep()
        case .microphone: MicrophoneStep()
        case .accessibility: AccessibilityStep()
        case .fnSetup: FnSetupStep()
        case .modelDownload: ModelDownloadStep(appState: appState)
        case .done: DoneStep()
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if currentStep == .done {
            Button("Finish") {
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
                onFinish()
            }
            .keyboardShortcut(.defaultAction)
        } else {
            Button(currentStep == .welcome ? "Get Started" : "Continue") {
                if stepIndex + 1 < steps.count {
                    stepIndex += 1
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Steps

@MainActor
private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Vocal")
                .font(.largeTitle)
                .bold()
            Text(
                """
                Hold the dictation key, speak in English or 中文, release — your \
                words appear where you were typing. Everything runs on this Mac: \
                audio and transcripts never leave it.
                """
            )
            Text("A couple of one-time permissions come first.")
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct MicrophoneStep: View {
    @State private var status: AVAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Microphone")
                .font(.title2)
                .bold()
            Text("Vocal records only while you hold the dictation key — never at idle.")
            statusLine
            if status != .authorized {
                Button("Allow Microphone Access") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        status = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
            }
        }
        .onAppear {
            status = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .authorized:
            Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied, .restricted:
            Text("Denied — enable Vocal under System Settings → Privacy & Security → Microphone.")
                .font(.caption)
                .foregroundStyle(.red)
        default:
            Text("Not granted yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct AccessibilityStep: View {
    @State private var trusted = false
    // Live re-check while this page is visible (docs/09): the grant flips in
    // System Settings with no notification to us, so poll once per second.
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accessibility")
                .font(.title2)
                .bold()
            Text(
                """
                Accessibility access powers the global hotkey and inserting text \
                into other apps. It also covers key monitoring — Vocal never asks \
                for Input Monitoring separately.
                """
            )
            if trusted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Not granted yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Request Accessibility Access") {
                    promptForAccessibility()
                }
            }
        }
        .onAppear { trusted = AXIsProcessTrusted() }
        .onReceive(recheck) { _ in trusted = AXIsProcessTrusted() }
    }

    private func promptForAccessibility() {
        // The header exposes kAXTrustedCheckOptionPrompt as a mutable global,
        // which Swift 6 rejects as non-concurrency-safe; its documented value
        // is the literal key string.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
private struct FnSetupStep: View {
    @State private var stillConfigured = true
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up the 🌐 Key")
                .font(.title2)
                .bold()
            Text(
                """
                Your 🌐 (Fn) key currently triggers a macOS action that Vocal \
                cannot suppress. In System Settings → Keyboard, set \
                “Press 🌐 key to” to “Do Nothing”. While there, also check the \
                Dictation shortcut so double-pressing Fn does not open Apple \
                Dictation.
                """
            )
            if stillConfigured {
                Button("Open Keyboard Settings") {
                    FnKeySetup.openKeyboardSettings()
                }
            } else {
                Label("🌐 key is set to Do Nothing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .onAppear { stillConfigured = FnKeySetup.globeKeyActionIsConfigured() }
        .onReceive(recheck) { _ in stillConfigured = FnKeySetup.globeKeyActionIsConfigured() }
    }
}

@MainActor
private struct ModelDownloadStep: View {
    let appState: AppState
    @State private var isWarming = false
    @State private var warmedUp = false
    @State private var warmUpError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech Model")
                .font(.title2)
                .bold()
            Text(
                """
                Vocal uses Whisper large-v3-turbo (about 600 MB), downloaded once \
                and stored locally. The download starts automatically on your \
                first dictation — or fetch and load it now so the first take is \
                instant.
                """
            )
            Button {
                warmUp()
            } label: {
                if isWarming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading & loading model…")
                    }
                } else if warmedUp {
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                } else {
                    Text("Warm Up Now")
                }
            }
            .disabled(isWarming || warmedUp)
            if let warmUpError {
                Text(warmUpError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func warmUp() {
        isWarming = true
        warmUpError = nil
        Task {
            do {
                try await appState.warmUp()
                warmedUp = true
            } catch {
                // A failed download must not show "Model ready" — the user
                // would finish onboarding believing the model is installed.
                warmUpError = "Download failed — check your connection and retry."
            }
            isWarming = false
        }
    }
}

@MainActor
private struct DoneStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're Set")
                .font(.largeTitle)
                .bold()
            Text(
                """
                Hold your dictation key, speak, release. Double-tap for \
                hands-free lock; press Escape while recording to cancel. \
                Everything else lives in the menu-bar icon.
                """
            )
        }
    }
}
