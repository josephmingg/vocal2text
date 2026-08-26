import BridgeKit
import Combine
import SwiftUI
import UIKit

/// Arming UI for the Vocal keyboard (docs/02 §3.1).
///
/// The screen's job is as much disclosure as control: an armed session holds a
/// live microphone session for its whole window, so the orange recording dot
/// stays lit and battery is spent. That is stated here, next to the switch
/// that causes it, rather than buried in a footnote.
struct KeyboardSessionView: View {
    @ObservedObject var coordinator: CaptureSessionCoordinator
    @State private var window: CaptureWindow = .default
    /// Ticks once a second so the countdown is live while this screen is open.
    @State private var tick = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            statusSection
            controlSection
            deliverySection
            setupSection
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(clock) { tick = $0 }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if !coordinator.isBridgeAvailable {
                Label(
                    "Vocal's App Group is unavailable, so the keyboard cannot reach the app.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else if let session = coordinator.session, session.isArmed(at: tick) {
                LabeledContent("Status") {
                    Text("Armed · \(Self.remainingText(session.remaining(at: tick)))")
                        .foregroundStyle(.green)
                }
                LabeledContent("Profile", value: session.profileName)
            } else {
                LabeledContent("Status") {
                    Text("Not armed").foregroundStyle(.secondary)
                }
            }
            if let notice = coordinator.lastNotice {
                Text(notice).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Capture session")
        } footer: {
            Text(
                "While a session is armed, tapping the mic on the Vocal keyboard records without "
                    + "leaving the app you are typing in. With no session armed, the mic key opens "
                    + "Vocal once — iOS offers no way to send you back automatically."
            )
        }
    }

    private var controlSection: some View {
        Section {
            Picker("Window", selection: $window) {
                ForEach(CaptureWindow.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            if let session = coordinator.session, session.isArmed(at: tick) {
                Button("Disarm now", role: .destructive) { coordinator.disarm() }
            } else {
                Button("Arm for \(window.displayName)") {
                    coordinator.arm(window: window, profileName: nil)
                }
                .disabled(!coordinator.isBridgeAvailable)
            }
        } footer: {
            Text(window.residencyDisclosure)
        }
    }

    private var deliverySection: some View {
        Section {
            Toggle("Insert without asking", isOn: $coordinator.autoInsert)
        } header: {
            Text("Keyboard delivery")
        } footer: {
            Text(
                coordinator.autoInsert
                    ? "Transcripts go straight into the field. Fast, but nothing is reviewed first."
                    : "The keyboard shows a one-line preview with ✓ and ✗ before anything is typed."
            )
        }
    }

    private var setupSection: some View {
        Section {
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: settings) {
                    Label("Open iPhone Settings", systemImage: "gear")
                }
            }
        } header: {
            Text("First-time setup")
        } footer: {
            Text(
                """
                1. Settings → General → Keyboard → Keyboards → Add New Keyboard → Vocal.
                2. Tap Vocal in that list and switch on Allow Full Access.

                iOS requires Full Access before a keyboard may open its own app or read its \
                shared storage — that is the only reason Vocal asks. The keyboard extension \
                links no networking framework at all; it can only read and write files in \
                Vocal's own App Group.
                """
            )
        }
    }

    // MARK: - Helpers

    static func remainingText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        if minutes >= 1 { return "\(minutes) min left" }
        return "\(total)s left"
    }
}
