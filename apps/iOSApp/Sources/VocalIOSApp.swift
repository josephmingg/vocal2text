import BridgeKit
import SwiftUI

/// iPhone companion (docs/02). Mode D1 — dictate in the app, transcript on the
/// clipboard — plus the D2b keyboard bridge, share-sheet voice-note import,
/// and the Dynamic Island recording indicator.
@main
struct VocalIOSApp: App {
    @StateObject private var appState: IOSAppState
    @StateObject private var coordinator = CaptureSessionCoordinator()
    @StateObject private var processor: ImportProcessor
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The import processor transcribes through the app's own engine, so
        // both wrappers are seeded from one instance rather than two.
        let appState = IOSAppState()
        _appState = StateObject(wrappedValue: appState)
        _processor = StateObject(wrappedValue: ImportProcessor(appState: appState))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                DictateView(appState: appState)
                    .tabItem { Label("Dictate", systemImage: "mic.fill") }
                IOSHistoryView(appState: appState)
                    .tabItem { Label("History", systemImage: "clock") }
                IOSDictionaryView(appState: appState)
                    .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                IOSSettingsView(
                    appState: appState, coordinator: coordinator, processor: processor
                )
                .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .onAppear {
                coordinator.attach(to: appState)
                processor.refresh()
            }
            .onOpenURL { url in
                coordinator.handle(url: url)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // Coming back to the foreground is the moment to pick up work
                // that arrived while the app was away: a keyboard request that
                // outlived a suspension, and newly shared voice notes.
                coordinator.applicationBecameActive()
                processor.refresh()
            }
        }
    }
}
