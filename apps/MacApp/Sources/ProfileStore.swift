import CoreModels
import Foundation
import PersistenceKit
import ProfileKit

/// The Mac app's live profile set (docs/11 G17): loads persisted profiles —
/// seeding the built-ins on first run so profile IDs survive relaunch
/// (FR-8.3) — publishes them to the menu-bar pin picker and the Settings
/// Profiles pane, and writes every edit through `DatabaseStore`. The
/// press-time profile resolution reads `profiles` at each hotkey press, so an
/// edit takes effect on the very next dictation without relaunching.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile]
    /// Latest failed-write message for the Settings pane; nil after a
    /// successful operation.
    @Published private(set) var lastErrorText: String?

    private let database: DatabaseStore?

    /// False when the database could not be opened: edits still work for this
    /// launch (in memory) but will not survive quitting — the pane says so.
    var persists: Bool { database != nil }

    init(database: DatabaseStore?) {
        self.database = database
        self.profiles = ProfileBootstrap.loadOrSeed(
            load: { try database?.profiles() ?? [] },
            save: { try database?.save($0) }
        )
    }

    func profile(id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Upserts one profile. The in-memory set is updated even when the write
    /// fails (the session resolves from memory, so the editor stays truthful
    /// about what the next dictation will use); the error is surfaced instead
    /// of silently dropping the edit.
    func save(_ profile: Profile) {
        do {
            try database?.save(profile)
            lastErrorText = nil
        } catch {
            lastErrorText = "Could not save profile: \(error.localizedDescription)"
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Creates and persists a blank profile, returning it for selection.
    /// Cleanup ships enabled on new profiles — creating one is already an
    /// explicit act, and the global master switch still gates everything
    /// (docs/05 §0).
    func addProfile() -> Profile {
        let profile = Profile(
            name: ProfileBootstrap.uniqueName(base: "New Profile", among: profiles),
            icon: "person.wave.2",
            cleanupEnabled: true
        )
        save(profile)
        return profile
    }

    /// Deletes a profile. The `.defaultRoute` owner is not deletable — the
    /// pane disables the button, and this guard keeps the docs/05 §4
    /// exactly-one-default invariant even if a caller forgets. A pin naming
    /// the deleted profile is cleared so routing does not silently ignore it.
    func delete(id: UUID) {
        guard let profile = profile(id: id),
              !profile.routes.contains(.defaultRoute)
        else { return }
        do {
            try database?.deleteProfile(id: id)
            lastErrorText = nil
        } catch {
            lastErrorText = "Could not delete profile: \(error.localizedDescription)"
            return
        }
        profiles.removeAll { $0.id == id }
        if PinState.shared.pinnedProfileID == id {
            PinState.shared.pinnedProfileID = nil
        }
    }

    /// Moves the default route to `id` (docs/05 §4: exactly one owner).
    func makeDefault(id: UUID) {
        guard let updated = ProfileBootstrap.makingDefault(id: id, in: profiles) else { return }
        let before = profiles
        for (index, profile) in updated.enumerated() where before[index] != profile {
            save(profile)
        }
    }
}
