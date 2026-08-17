import CoreModels
import Foundation

/// The five starter profiles from docs/05 §4, pre-authored so cleanup works
/// the moment the user opts in. `ProfileBootstrap.loadOrSeed` writes them to
/// the profile store on first run; from then on the persisted set is the
/// truth and these are ordinary editable, deletable profiles (docs/11 G17 —
/// the Mac Settings → Profiles pane edits them; iOS has no editor yet).
///
/// Shipped `cleanupEnabled` state: every profile ships `true` EXCEPT
/// Terminal / Code (`false`). This is safe because the global cleanup master
/// switch ships OFF and gates stage 3 entirely regardless of per-profile
/// flags (docs/05 §0 precedence: master OFF → stage 3 never runs; master ON →
/// per-profile `cleanupEnabled` decides). Flipping the master switch therefore
/// activates every pre-authored configuration except Terminal / Code, whose
/// verbatim formatting gates additionally apply regardless of the master
/// switch.
public enum BuiltInProfiles: Sendable {
    /// Builds fresh copies (new UUIDs) of all five starter profiles.
    public static func makeAll() -> [Profile] {
        [defaultProfile(), messages(), email(), terminal(), notes()]
    }

    /// Owns `.defaultRoute`. Light touch: fillers, self-corrections,
    /// punctuation — no restyle.
    private static func defaultProfile() -> Profile {
        Profile(
            name: "Default",
            icon: "wand.and.stars",
            cleanupEnabled: true,
            promptText: """
                Apply spoken self-corrections, keeping only the corrected \
                content. Remove filler words (um, uh, you know; 嗯、呃、那个) \
                when they carry no meaning. Repair punctuation and sentence \
                breaks. Make no other changes: keep the speaker's wording, \
                tone, and structure exactly as dictated.
                """,
            routes: [.defaultRoute]
        )
    }

    /// Chat apps: casual, lowercase-friendly, no forced terminal period.
    private static func messages() -> Profile {
        Profile(
            name: "Messages",
            icon: "message",
            cleanupEnabled: true,
            promptText: """
                This is a casual chat message. Keep the speaker's voice and \
                keep it informal: lowercase-friendly English is fine, and a \
                short message needs no terminal period. Preserve any emoji; \
                when the speaker names one aloud, such as smiley face, you \
                may replace those words with the emoji. Never make the \
                message sound formal or businesslike.
                """,
            routes: [
                .app(bundleID: "com.tinyspeck.slackmacgap"),
                .app(bundleID: "com.tencent.xinWeChat"),
                .app(bundleID: "com.apple.MobileSMS"),
                .app(bundleID: "com.hnc.Discord"),
                .app(bundleID: "ru.keepcoder.Telegram"),
            ]
        )
    }

    /// Mail app plus webmail hostnames: professional, full sentences,
    /// paragraphs allowed.
    private static func email() -> Profile {
        Profile(
            name: "Email",
            icon: "envelope",
            cleanupEnabled: true,
            promptText: """
                This is an email. Write full, grammatical sentences in a \
                professional tone and break the text into paragraphs where \
                the topic shifts. Leave any greeting and sign-off exactly as \
                dictated. Do not add pleasantries or any content the speaker \
                did not say.
                """,
            formatting: FormattingOptions(structureAllowed: true),
            routes: [
                .app(bundleID: "com.apple.mail"),
                .website(hostname: "mail.google.com"),
                .website(hostname: "outlook.live.com"),
                .website(hostname: "outlook.office.com"),
            ]
        )
    }

    /// Terminals and editors: verbatim mode — cleanup off, formatting gates
    /// off, global style ignored; only artifact stripping and dictionary
    /// overrides apply (docs/05 §0). The prompt still documents the intent in
    /// case the user ever enables cleanup here.
    private static func terminal() -> Profile {
        Profile(
            name: "Terminal / Code",
            icon: "terminal",
            cleanupEnabled: false,
            promptText: """
                Do not change this text in any way. It may be a shell command \
                or code, where added punctuation, capitalization, or reworded \
                tokens break it. Return it verbatim.
                """,
            formatting: .verbatim,
            ignoresGlobalStyle: true,
            routes: [
                .app(bundleID: "com.apple.Terminal"),
                .app(bundleID: "com.googlecode.iterm2"),
                .app(bundleID: "com.mitchellh.ghostty"),
                .app(bundleID: "com.microsoft.VSCode"),
                .app(bundleID: "com.apple.dt.Xcode"),
                .app(bundleID: "com.todesktop.230313mzl4w4u92"),
            ]
        )
    }

    /// Note-taking apps and Google Docs: structure allowed — paragraphs and
    /// lists when the speaker enumerates.
    private static func notes() -> Profile {
        Profile(
            name: "Notes / Docs",
            icon: "note.text",
            cleanupEnabled: true,
            promptText: """
                These are notes. Organize the dictation: paragraphs on topic \
                shifts, and when the speaker enumerates items (first, \
                second, third; 第一、第二), render them as a bullet or \
                numbered list. Keep the speaker's wording with minimal edits \
                only.
                """,
            formatting: FormattingOptions(structureAllowed: true),
            routes: [
                .app(bundleID: "com.apple.Notes"),
                .app(bundleID: "md.obsidian"),
                .app(bundleID: "com.apple.iWork.Pages"),
                .website(hostname: "docs.google.com"),
            ]
        )
    }
}
