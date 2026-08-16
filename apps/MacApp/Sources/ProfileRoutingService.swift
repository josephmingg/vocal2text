import CoreModels
import Foundation
import ProfileKit

/// Bridges press-time context to ProfileKit for the session's
/// `profileResolution` dependency (docs/05 §4 routing; FR-3.6 pins the result
/// for the whole take).
///
/// The resolver is re-read through a provider closure on every resolution so
/// profile edits apply to the next dictation without rebuilding the service;
/// the manual-pin closure feeds FR-8.3 (return nil while no pin is active).
final class ProfileRoutingService: Sendable {

    private let resolverProvider: @Sendable () -> ProfileResolver
    private let context: FrontmostContext
    private let manualPin: @Sendable () -> UUID?

    init(
        resolverProvider: @escaping @Sendable () -> ProfileResolver,
        context: FrontmostContext,
        manualPin: @escaping @Sendable () -> UUID?
    ) {
        self.resolverProvider = resolverProvider
        self.context = context
        self.manualPin = manualPin
    }

    /// Resolves the profile for one dictation. Blocking (up to ~1.5 s inside
    /// the browser-URL fetch) — call from the background async context of
    /// `DictationSession.Dependencies.profileResolution`, whose tuple shape
    /// this return matches exactly.
    func resolveNow() -> (
        profile: Profile,
        routeKind: TranscriptRecord.RouteKind,
        pressTimeBundleID: String?
    ) {
        let snapshot = context.snapshot()
        let resolution = resolverProvider().resolve(
            frontmostBundleID: snapshot.bundleID,
            tabHostname: snapshot.tabHostname,
            manualPinProfileID: manualPin()
        )
        return (
            profile: resolution.profile,
            routeKind: resolution.routeKind,
            pressTimeBundleID: snapshot.bundleID
        )
    }
}
