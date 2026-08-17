import CoreModels
import Foundation
import ProfileKit
import Testing

private func makeProfile(
    name: String,
    routes: [Route],
    priority: Int = 0
) -> Profile {
    Profile(name: name, cleanupEnabled: true, routes: routes, priority: priority)
}

// MARK: - Precedence

@Test func websiteRouteBeatsAppRouteWhenBothMatch() {
    let browser = makeProfile(name: "Browser", routes: [.app(bundleID: "com.apple.Safari")])
    let email = makeProfile(name: "Email", routes: [.website(hostname: "google.com")])
    let resolver = ProfileResolver(profiles: [browser, email])

    let resolution = resolver.resolve(
        frontmostBundleID: "com.apple.Safari",
        tabHostname: "mail.google.com",
        manualPinProfileID: nil
    )

    #expect(resolution.profile == email)
    #expect(resolution.routeKind == .website)
}

@Test func manualPinBeatsAllRouting() {
    let browser = makeProfile(name: "Browser", routes: [.app(bundleID: "com.apple.Safari")])
    let email = makeProfile(name: "Email", routes: [.website(hostname: "google.com")])
    let pinned = makeProfile(name: "Pinned", routes: [])
    let resolver = ProfileResolver(profiles: [browser, email, pinned])

    let resolution = resolver.resolve(
        frontmostBundleID: "com.apple.Safari",
        tabHostname: "mail.google.com",
        manualPinProfileID: pinned.id
    )

    #expect(resolution.profile == pinned)
    #expect(resolution.routeKind == .manualPin)
}

@Test func unknownManualPinFallsThroughToRouting() {
    let email = makeProfile(name: "Email", routes: [.website(hostname: "google.com")])
    let resolver = ProfileResolver(profiles: [email])

    let resolution = resolver.resolve(
        frontmostBundleID: "com.apple.Safari",
        tabHostname: "mail.google.com",
        manualPinProfileID: UUID()
    )

    #expect(resolution.profile == email)
    #expect(resolution.routeKind == .website)
}

@Test func websiteRoutesIgnoredWithoutTabHostname() {
    let email = makeProfile(name: "Email", routes: [.website(hostname: "google.com")])
    let fallback = makeProfile(name: "My Default", routes: [.defaultRoute])
    let resolver = ProfileResolver(profiles: [email, fallback])

    let resolution = resolver.resolve(
        frontmostBundleID: "com.apple.Safari",
        tabHostname: nil,
        manualPinProfileID: nil
    )

    #expect(resolution.profile == fallback)
    #expect(resolution.routeKind == .defaultRoute)
}

// MARK: - App routes

@Test func appRouteMatchesBundleIDCaseInsensitively() {
    let slack = makeProfile(name: "Messages", routes: [.app(bundleID: "com.tinyspeck.slackmacgap")])
    let resolver = ProfileResolver(profiles: [slack])

    let resolution = resolver.resolve(
        frontmostBundleID: "COM.TINYSPECK.SLACKMACGAP",
        tabHostname: nil,
        manualPinProfileID: nil
    )

    #expect(resolution.profile == slack)
    #expect(resolution.routeKind == .app)
}

// MARK: - Default fallback

@Test func unmatchedContextFallsBackToDefaultOwner() {
    let slack = makeProfile(name: "Messages", routes: [.app(bundleID: "com.tinyspeck.slackmacgap")])
    let fallback = makeProfile(name: "My Default", routes: [.defaultRoute])
    let resolver = ProfileResolver(profiles: [slack, fallback])

    let resolution = resolver.resolve(
        frontmostBundleID: "com.unknown.app",
        tabHostname: nil,
        manualPinProfileID: nil
    )

    #expect(resolution.profile == fallback)
    #expect(resolution.routeKind == .defaultRoute)
}

@Test func synthesizesDefaultWhenNoProfileOwnsDefaultRoute() {
    let resolver = ProfileResolver(profiles: [])

    let resolution = resolver.resolve(
        frontmostBundleID: nil,
        tabHostname: nil,
        manualPinProfileID: nil
    )

    #expect(resolution.profile.name == "Default")
    #expect(resolution.profile.cleanupEnabled == false)
    #expect(resolution.profile.formatting == FormattingOptions())
    #expect(resolution.routeKind == .defaultRoute)
}

// MARK: - Priority and ties

@Test func higherPriorityWinsAmongEqualMatches() {
    let general = makeProfile(name: "General", routes: [.website(hostname: "google.com")], priority: 0)
    let specific = makeProfile(name: "Work Email", routes: [.website(hostname: "google.com")], priority: 10)
    let resolver = ProfileResolver(profiles: [general, specific])

    let resolution = resolver.resolve(
        frontmostBundleID: nil,
        tabHostname: "mail.google.com",
        manualPinProfileID: nil
    )

    #expect(resolution.profile == specific)
}

@Test func equalPriorityTieBreaksByNameAscending() {
    let zulu = makeProfile(name: "Zulu", routes: [.website(hostname: "google.com")], priority: 3)
    let alpha = makeProfile(name: "Alpha", routes: [.website(hostname: "google.com")], priority: 3)

    for profiles in [[zulu, alpha], [alpha, zulu]] {
        let resolver = ProfileResolver(profiles: profiles)
        let resolution = resolver.resolve(
            frontmostBundleID: nil,
            tabHostname: "mail.google.com",
            manualPinProfileID: nil
        )
        #expect(resolution.profile == alpha)
    }
}

// MARK: - Built-in profiles

@Test func builtInTerminalResolvesVerbatim() {
    let resolver = ProfileResolver(profiles: BuiltInProfiles.makeAll())

    let resolution = resolver.resolve(
        frontmostBundleID: "com.apple.Terminal",
        tabHostname: nil,
        manualPinProfileID: nil
    )

    #expect(resolution.profile.name == "Terminal / Code")
    #expect(resolution.profile.formatting == .verbatim)
    #expect(resolution.profile.cleanupEnabled == false)
    #expect(resolution.profile.ignoresGlobalStyle)
    #expect(resolution.routeKind == .app)
}

@Test func builtInEmailRoutesGmailHostname() {
    let resolver = ProfileResolver(profiles: BuiltInProfiles.makeAll())

    let resolution = resolver.resolve(
        frontmostBundleID: "com.apple.Safari",
        tabHostname: "mail.google.com",
        manualPinProfileID: nil
    )

    #expect(resolution.profile.name == "Email")
    #expect(resolution.routeKind == .website)
}

@Test func builtInNotesRoutesGoogleDocsHostname() {
    let resolver = ProfileResolver(profiles: BuiltInProfiles.makeAll())

    let resolution = resolver.resolve(
        frontmostBundleID: "com.google.Chrome",
        tabHostname: "docs.google.com",
        manualPinProfileID: nil
    )

    #expect(resolution.profile.name == "Notes / Docs")
    #expect(resolution.routeKind == .website)
}

@Test func builtInMessagesRoutesSlackBundleID() {
    let resolver = ProfileResolver(profiles: BuiltInProfiles.makeAll())

    let resolution = resolver.resolve(
        frontmostBundleID: "com.tinyspeck.slackmacgap",
        tabHostname: nil,
        manualPinProfileID: nil
    )

    #expect(resolution.profile.name == "Messages")
    #expect(resolution.routeKind == .app)
}

@Test func builtInsShipFiveProfilesWithOneDefaultOwner() throws {
    let all = BuiltInProfiles.makeAll()
    #expect(all.count == 5)

    let owners = all.filter { $0.routes.contains(.defaultRoute) }
    #expect(owners.count == 1)
    let owner = try #require(owners.first)
    #expect(owner.name == "Default")
}

@Test func builtInsShipCleanupEnabledExceptTerminal() {
    for profile in BuiltInProfiles.makeAll() {
        #expect(profile.cleanupEnabled == (profile.name != "Terminal / Code"))
    }
}
