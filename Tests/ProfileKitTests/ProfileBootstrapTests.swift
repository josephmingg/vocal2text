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
