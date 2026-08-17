import AppIntents
import Foundation

/// "Start Dictation" App Intent (docs/02 FR-i1.2): exposed to Shortcuts, so it
/// binds to the Action Button, Back Tap, or a Lock Screen shortcut. It opens
/// the app and arms an auto-start flag DictateView consumes on appear.
struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription(
        "Opens Vocal and starts listening immediately."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "pendingAutoStart")
        return .result()
    }
}

/// Surfaces the intent in Shortcuts with sensible phrases.
struct VocalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: ["Start dictation in \(.applicationName)"],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
    }
}
