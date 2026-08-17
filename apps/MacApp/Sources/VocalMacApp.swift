import SwiftUI

/// Menu-bar-only app shell (docs/03 §3.4): `MenuBarExtra(.window)` hosts the
/// dropdown; the HUD panel and any AppKit-managed windows are owned by
/// `AppDelegate`. `LSUIElement` is set in the target's Info.plist.
@main
struct VocalMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appDelegate.appState)
        } label: {
            MenuBarStatusIcon(appState: appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar icon reflecting dictation state (FR-4.3: idle / listening /
/// processing / error — visible even when the HUD is disabled). A separate
/// observing view because the `MenuBarExtra("…", systemImage:)` initializer
/// cannot re-render when `hudState` (nested inside AppState) changes.
private struct MenuBarStatusIcon: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("Vocal")
    }

    private var symbolName: String {
        switch appState.hudState.mode {
        case .hidden: return "mic"
        case .listening: return "mic.fill"
        case .processing: return "waveform"
        case .error: return "mic.slash"
        case .notice: return "info.circle"
        }
    }
}
