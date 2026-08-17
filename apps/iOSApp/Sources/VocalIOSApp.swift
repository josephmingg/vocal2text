import SwiftUI

/// iPhone companion (docs/02): main-app dictation with auto-copy delivery
/// (mode D1). The keyboard extension (D2b) is the next milestone; this app is
/// already fully useful via Action Button → dictate → paste.
@main
struct VocalIOSApp: App {
    @StateObject private var appState = IOSAppState()

    var body: some Scene {
        WindowGroup {
            TabView {
                DictateView(appState: appState)
                    .tabItem { Label("Dictate", systemImage: "mic.fill") }
                IOSHistoryView(appState: appState)
                    .tabItem { Label("History", systemImage: "clock") }
                IOSDictionaryView(appState: appState)
                    .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                IOSSettingsView(appState: appState)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}
