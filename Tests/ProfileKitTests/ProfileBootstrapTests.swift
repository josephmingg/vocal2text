import CoreModels
import Foundation
import ProfileKit
import Testing

/// In-memory stand-in for the persisted profile table, keyed like the real
/// one (upsert by id).
private final class FakeStore {
    var profiles: [Profile] = []
    var loadError: Error?
    var saveError: Error?
    var saveCount = 0

    func load() throws -> [Profile] {
        if let loadError { throw loadError }
        return profiles
    }

    func save(_ profile: Profile) throws {
        saveCount += 1
        if let saveError { throw saveError }
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
    }
}

private struct StoreError: Error {}

// MARK: - loadOrSeed

@Test func emptyStoreIsSeededWithTheBuiltIns() {
    let store = FakeStore()

    let loaded = ProfileBootstrap.loadOrSeed(load: store.load, save: store.save)

    #expect(loaded.count == BuiltInProfiles.makeAll().count)
    // What was returned is exactly what was persisted — same IDs, so the set
    // the app runs with this launch is the set every later launch loads.
    #expect(store.profiles == loaded)
}

@Test func seededIDsSurviveARelaunch() {
    let store = FakeStore()

    let first = ProfileBootstrap.loadOrSeed(load: store.load, save: store.save)
    let second = ProfileBootstrap.loadOrSeed(load: store.load, save: store.save)

    #expect(second == first)
    // The second launch loaded; it must not have re-seeded on top.
    #expect(store.saveCount == first.count)
}

@Test func nonEmptyStoreIsReturnedVerbatimWithoutSaving() {
    let store = FakeStore()
    let custom = Profile(name: "Mine", cleanupEnabled: true, routes: [.defaultRoute])
    store.profiles = [custom]

    let loaded = ProfileBootstrap.loadOrSeed(load: store.load, save: store.save)

    #expect(loaded == [custom])
    #expect(store.saveCount == 0)
}

@Test func unreadableStoreFallsBackToBuiltInsWithoutSeeding() {
    let store = FakeStore()
    store.loadError = StoreError()

    let loaded = ProfileBootstrap.loadOrSeed(load: store.load, save: store.save)

    // The app still gets a working set, but nothing is written: upserting
    // new-ID built-ins next to an unreadable-but-present table would
    // duplicate every profile once the table reads again.
    #expect(loaded.count == BuiltInProfiles.makeAll().count)
    #expect(store.saveCount == 0)
}

@Test func failingSavesStillYieldTheFullBuiltInSet() {
    let store = FakeStore()
    store.saveError = StoreError()

    let loaded = ProfileBootstrap.loadOrSeed(load: store.load, save: store.save)

    #expect(loaded.count == BuiltInProfiles.makeAll().count)
    // Every save was attempted, none landed; the app runs from memory.
    #expect(store.saveCount == loaded.count)
    #expect(store.profiles.isEmpty)
}

// MARK: - makingDefault

@Test func makingDefaultMovesTheRouteFromTheCurrentOwner() throws {
    let profiles = BuiltInProfiles.makeAll()
    let messages = try #require(profiles.first { $0.name == "Messages" })
    let oldOwner = try #require(profiles.first { $0.routes.contains(.defaultRoute) })

    let updated = try #require(ProfileBootstrap.makingDefault(id: messages.id, in: profiles))

    let owners = updated.filter { $0.routes.contains(.defaultRoute) }
    #expect(owners.map(\.id) == [messages.id])
    // The old owner kept everything but the default route.
    let previous = try #require(updated.first { $0.id == oldOwner.id })
    #expect(previous.routes == oldOwner.routes.filter { $0 != .defaultRoute })
    // The new owner's existing routes are intact alongside the default.
    let promoted = try #require(updated.first { $0.id == messages.id })
    #expect(Set(promoted.routes) == Set(messages.routes + [.defaultRoute]))
}

@Test func makingDefaultIsANoOpForTheCurrentOwnerAndUnknownIDs() {
    let profiles = BuiltInProfiles.makeAll()
    let owner = profiles.first { $0.routes.contains(.defaultRoute) }

    #expect(ProfileBootstrap.makingDefault(id: owner?.id ?? UUID(), in: profiles) == nil)
    #expect(ProfileBootstrap.makingDefault(id: UUID(), in: profiles) == nil)
}

// MARK: - uniqueName

@Test func uniqueNameCountsPastTakenNames() {
    let profiles = [
        Profile(name: "New Profile"),
        Profile(name: "New Profile 2"),
    ]

    #expect(ProfileBootstrap.uniqueName(base: "New Profile", among: profiles) == "New Profile 3")
    #expect(ProfileBootstrap.uniqueName(base: "Meeting Notes", among: profiles) == "Meeting Notes")
}

// MARK: - docs/17: built-in upgrades reach existing installs once

/// The v1 built-in set as an install seeded before docs/17 holds it.
private func versionOneProfiles() -> [Profile] {
    var profiles = BuiltInProfiles.makeAll().filter { $0.name != "AI Prompt" }
    let laterTerminals: Set<String> = [
        "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "dev.warp.Warp-Stable",
    ]
    for index in profiles.indices {
        profiles[index].routes.removeAll {
            if case .app(let bundleID) = $0 { return laterTerminals.contains(bundleID) }
            return false
        }
    }
    return profiles
}

@Test func upgradeAddsTerminalRoutesAndTheAIPromptProfileOnce() {
    var saved: [Profile] = []
    let upgraded = ProfileBootstrap.applyingUpgrades(
        to: versionOneProfiles(), fromVersion: 1, save: { saved.append($0) }
    )
    let resolver = ProfileResolver(profiles: upgraded)
    #expect(
        resolver.resolve(frontmostBundleID: "net.kovidgoyal.kitty", tabHostname: nil, manualPinProfileID: nil)
            .profile.name == "Terminal / Code"
    )
    #expect(
        resolver.resolve(frontmostBundleID: "com.apple.Safari", tabHostname: "claude.ai", manualPinProfileID: nil)
            .profile.name == "AI Prompt"
    )
    #expect(saved.map(\.name).sorted() == ["AI Prompt", "Terminal / Code"])
    // Idempotent: a second pass (or a fresh install) changes nothing.
    var savedAgain: [Profile] = []
    let again = ProfileBootstrap.applyingUpgrades(to: upgraded, fromVersion: 1, save: { savedAgain.append($0) })
    #expect(again == upgraded)
    #expect(savedAgain.isEmpty)
}

@Test func upgradeNeverStealsARouteTheUserGaveAnotherProfile() {
    var profiles = versionOneProfiles()
    profiles.append(Profile(name: "My Kitty", routes: [.app(bundleID: "net.kovidgoyal.kitty")]))
    profiles.append(Profile(name: "My Claude", routes: [.app(bundleID: "com.anthropic.claudefordesktop")]))
    let upgraded = ProfileBootstrap.applyingUpgrades(to: profiles, fromVersion: 1, save: { _ in })
    let resolver = ProfileResolver(profiles: upgraded)
    #expect(
        resolver.resolve(frontmostBundleID: "net.kovidgoyal.kitty", tabHostname: nil, manualPinProfileID: nil)
            .profile.name == "My Kitty"
    )
    // The user already routes an AI app themselves: no AI Prompt profile.
    #expect(!upgraded.contains { $0.name == "AI Prompt" })
}

@Test func upgradeIsSkippedAtTheCurrentVersion() {
    let profiles = versionOneProfiles()
    let upgraded = ProfileBootstrap.applyingUpgrades(
        to: profiles, fromVersion: ProfileBootstrap.builtInVersion, save: { _ in Issue.record("saved") }
    )
    #expect(upgraded == profiles)
}

@Test func anUnreadableStoreGetsNoUpgradeWritesAndNoRecordedVersion() {
    struct Unreadable: Error {}
    var recorded: Int?
    let profiles = ProfileBootstrap.loadSeedingAndUpgrading(
        load: { throw Unreadable() },
        save: { _ in Issue.record("must not write to an unreadable store") },
        storedVersion: 0,
        recordVersion: { recorded = $0 }
    )
    #expect(profiles.count == BuiltInProfiles.makeAll().count)
    #expect(recorded == nil)
}

@Test func aFreshInstallSeedsTheCurrentSetAndRecordsTheVersion() {
    var saved: [Profile] = []
    var recorded: Int?
    let profiles = ProfileBootstrap.loadSeedingAndUpgrading(
        load: { [] },
        save: { saved.append($0) },
        storedVersion: 0,
        recordVersion: { recorded = $0 }
    )
    #expect(profiles.count == BuiltInProfiles.makeAll().count)
    #expect(saved.count == profiles.count)
    #expect(recorded == ProfileBootstrap.builtInVersion)
}
