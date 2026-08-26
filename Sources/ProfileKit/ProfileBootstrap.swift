import CoreModels
import Foundation

/// First-run seeding and pure edit helpers behind the profile editor
/// (docs/11 G17). Closure-based rather than depending on PersistenceKit so
/// the logic tests on Linux and both apps share one bootstrap path.
public enum ProfileBootstrap: Sendable {
    /// Returns the persisted profile set, seeding the built-in starter
    /// profiles through `save` when the store is empty.
    ///
    /// Seeding writes the built-ins to the store so their UUIDs are minted
    /// once and stay stable across launches — a menu-bar pin or a per-profile
    /// setting must keep meaning the same profile tomorrow (FR-8.3; the old
    /// in-memory `BuiltInProfiles.makeAll()` fallback minted fresh IDs every
    /// launch).
    ///
    /// Failure posture:
    /// - `load` throws (store unreadable): return fresh built-ins WITHOUT
    ///   seeding. Upserting five new-ID built-ins next to an unreadable-but-
    ///   present set would duplicate profiles the moment the store reads again.
    /// - one `save` throws: keep seeding the rest and return the full built-in
    ///   set anyway — the app works from memory this launch and the next
    ///   launch retries whatever is missing only if the store stayed empty.
    public static func loadOrSeed(
        load: () throws -> [Profile],
        save: (Profile) throws -> Void
    ) -> [Profile] {
        do {
            let stored = try load()
            if !stored.isEmpty { return stored }
        } catch {
            return BuiltInProfiles.makeAll()
        }
        let seeded = BuiltInProfiles.makeAll()
        for profile in seeded {
            try? save(profile)
        }
        return seeded
    }

    /// Moves the `.defaultRoute` to the profile with `id`, removing it from
    /// every current owner, and returns the full updated set — or nil when
    /// `id` is unknown or already the owner (nothing to change). Keeps the
    /// docs/05 §4 invariant: exactly one profile owns the default route.
    public static func makingDefault(id: UUID, in profiles: [Profile]) -> [Profile]? {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].routes.contains(.defaultRoute)
        else { return nil }
        var updated = profiles
        for i in updated.indices {
            updated[i].routes.removeAll { $0 == .defaultRoute }
        }
        updated[index].routes.append(.defaultRoute)
        return updated
    }

    /// A profile name not already taken, for freshly added profiles:
    /// "New Profile", then "New Profile 2", … Names are only cosmetic to the
    /// resolver (identity is the UUID), but two identical rows in the editor
    /// list would be indistinguishable.
    public static func uniqueName(base: String, among profiles: [Profile]) -> String {
        let taken = Set(profiles.map(\.name))
        if !taken.contains(base) { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }
}
