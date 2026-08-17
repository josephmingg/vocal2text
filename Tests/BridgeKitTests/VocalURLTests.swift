import Foundation
import Testing

@testable import BridgeKit

@Suite("Deep links")
struct VocalURLTests {

    @Test("Every link round-trips through its URL")
    func roundTrip() throws {
        let cases: [VocalURL] = [
            .dictate,
            .imports,
            .arm(window: .fiveMinutes, profileName: nil),
            .arm(window: .sixtyMinutes, profileName: "Chat"),
        ]
        for link in cases {
            #expect(VocalURL(link.url) == link, "round-trip failed for \(link)")
        }
    }

    @Test("Profile names with spaces survive the round-trip")
    func percentEncodedProfile() throws {
        let link = VocalURL.arm(window: .fifteenMinutes, profileName: "Work email")
        #expect(VocalURL(link.url) == link)
        #expect(link.url.absoluteString.contains("profile=Work%20email"))
    }

    @Test("Foreign and malformed links are declined")
    func declinesForeignLinks() throws {
        #expect(VocalURL(try #require(URL(string: "https://example.com/arm"))) == nil)
        #expect(VocalURL(try #require(URL(string: "vocal://unknown"))) == nil)
        #expect(VocalURL(try #require(URL(string: "vocal://arm.evil"))) == nil)
        // A host-less link is not actionable either; some Foundation versions
        // decline to parse it at all, which is equally fine.
        if let bare = URL(string: "vocal://") {
            #expect(VocalURL(bare) == nil)
        }
    }

    @Test("Scheme matching is case-insensitive")
    func schemeIsCaseInsensitive() throws {
        #expect(VocalURL(try #require(URL(string: "VOCAL://dictate"))) == .dictate)
    }

    @Test("An unknown window falls back to the cheapest one")
    func unknownWindowFallsBack() throws {
        #expect(
            VocalURL(try #require(URL(string: "vocal://arm?window=forever")))
                == .arm(window: .default, profileName: nil)
        )
        #expect(
            VocalURL(try #require(URL(string: "vocal://arm")))
                == .arm(window: .default, profileName: nil)
        )
    }

    @Test("An empty profile parameter reads as no profile")
    func emptyProfileIsNil() throws {
        #expect(
            VocalURL(try #require(URL(string: "vocal://arm?window=fiveMinutes&profile=")))
                == .arm(window: .fiveMinutes, profileName: nil)
        )
    }
}

@Suite("Live Activity presentation")
struct RecordingActivityTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(
        _ stage: RecordingActivityState.Stage,
        preview: String? = nil,
        failureReason: String? = nil
    ) -> RecordingActivityState {
        RecordingActivityState(
            stage: stage,
            startedAt: epoch,
            profileName: "Chat",
            preview: preview,
            failureReason: failureReason
        )
    }

    @Test("Every stage has a title and a symbol")
    func everyStageRenders() {
        let stages: [RecordingActivityState.Stage] = [
            .recording, .transcribing, .cleaning, .delivering, .finished, .failed,
        ]
        for stage in stages {
            #expect(!RecordingActivityPresenter.title(for: state(stage)).isEmpty)
            #expect(!RecordingActivityPresenter.symbolName(for: state(stage)).isEmpty)
        }
    }

    @Test("Only in-flight stages animate")
    func liveStages() {
        #expect(RecordingActivityPresenter.isLive(state(.recording)))
        #expect(RecordingActivityPresenter.isLive(state(.transcribing)))
        #expect(RecordingActivityPresenter.isLive(state(.cleaning)))
        #expect(RecordingActivityPresenter.isLive(state(.delivering)))
        #expect(!RecordingActivityPresenter.isLive(state(.finished)))
        #expect(!RecordingActivityPresenter.isLive(state(.failed)))
    }

    @Test("Subtitle prefers a failure reason, then a preview, then the profile")
    func subtitlePrecedence() {
        #expect(
            RecordingActivityPresenter.subtitle(
                for: state(.failed, preview: "hi", failureReason: "no model")
            ) == "no model"
        )
        #expect(RecordingActivityPresenter.subtitle(for: state(.finished, preview: "hi")) == "hi")
        #expect(RecordingActivityPresenter.subtitle(for: state(.recording)) == "Chat")
        // A failed stage with no reason still says something useful.
        #expect(RecordingActivityPresenter.subtitle(for: state(.failed)) == "Chat")
    }

    @Test("Previews are trimmed for a locked screen")
    func previewTruncation() {
        #expect(RecordingActivityState.makePreview(from: "   ") == nil)
        #expect(RecordingActivityState.makePreview(from: "  hello  ") == "hello")

        let long = String(repeating: "a", count: 200)
        let preview = RecordingActivityState.makePreview(from: long)
        #expect(preview?.hasSuffix("…") == true)
        #expect(preview?.count == RecordingActivityState.previewCharacterLimit + 1)

        // Exactly at the limit is shown whole, with no ellipsis.
        let exact = String(repeating: "b", count: RecordingActivityState.previewCharacterLimit)
        #expect(RecordingActivityState.makePreview(from: exact) == exact)
    }

    @Test("Elapsed time is m:ss and never negative")
    func elapsedFormatting() {
        #expect(RecordingActivityPresenter.elapsedText(for: state(.recording), at: epoch) == "0:00")
        #expect(
            RecordingActivityPresenter.elapsedText(
                for: state(.recording), at: epoch.addingTimeInterval(9)
            ) == "0:09"
        )
        #expect(
            RecordingActivityPresenter.elapsedText(
                for: state(.recording), at: epoch.addingTimeInterval(605)
            ) == "10:05"
        )
        // A clock that jumped backwards must not render "-1:-5".
        #expect(
            RecordingActivityPresenter.elapsedText(
                for: state(.recording), at: epoch.addingTimeInterval(-30)
            ) == "0:00"
        )
    }

    @Test("The compact island shows a timer while live and a verdict after")
    func compactTrailing() {
        #expect(
            RecordingActivityPresenter.compactTrailing(
                for: state(.recording), at: epoch.addingTimeInterval(65)
            ) == "1:05"
        )
        #expect(
            RecordingActivityPresenter.compactTrailing(for: state(.finished), at: epoch)
                == "Ready to paste"
        )
    }

    @Test("A preview built from a take is language-labelled")
    func previewWithLanguage() {
        let labelled = state(.finished).withPreview("你好，世界", language: .chinese)
        #expect(labelled.preview == "中文 · 你好，世界")
        let unlabelled = state(.finished).withPreview("hello", language: nil)
        #expect(unlabelled.preview == "hello")
    }
}
