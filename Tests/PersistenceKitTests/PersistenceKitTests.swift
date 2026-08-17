import CoreModels
import Foundation
import PersistenceKit
import Testing

#if canImport(GRDB)
import GRDB

private func makeStore() throws -> (store: DatabaseStore, path: String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("vocal-db-test-\(UUID().uuidString).sqlite")
        .path
    return (try DatabaseStore(path: path), path)
}

private func makeRecord(
    rawText: String,
    deliveredText: String? = nil,
    language: Language = .english,
    createdAt: Date = Date(timeIntervalSince1970: 1_723_000_000)
) -> TranscriptRecord {
    TranscriptRecord(
        createdAt: createdAt,
        source: .dictation,
        language: language,
        rawText: rawText,
        deliveredText: deliveredText ?? rawText,
        durationSeconds: 2.5,
        profileName: "Default",
        routeKind: .defaultRoute,
        cleanup: .skipped(reason: .masterSwitchOff)
    )
}

@Test func persistenceIsSupportedWithGRDB() {
    #expect(PersistenceInfo.isSupported)
}

// MARK: - Transcript round-trip

@Test func saveAndFetchRoundTrips() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let record = TranscriptRecord(
        createdAt: Date(timeIntervalSince1970: 1_723_111_111),
        source: .fileImport,
        language: .chinese,
        rawText: "周六去爬山吗",
        deliveredText: "周六去爬山吗？",
        durationSeconds: 3.25,
        targetAppBundleID: "com.tinyspeck.slackmacgap",
        targetAppName: "Slack",
        profileName: "Messages",
        routeKind: .app,
        cleanup: .applied(provider: .ollama(model: "qwen3:4b"), model: "qwen3:4b"),
        timings: TimingBreakdown(
            captureSeconds: 3.25,
            transcriptionSeconds: 0.5,
            dictionarySeconds: 0.25,
            cleanupSeconds: 1.0,
            deliverySeconds: 0.125
        ),
        audioPath: "audio/take.caf",
        isCancelled: false,
        importedFilename: "meeting.m4a"
    )
    try store.save(record)

    #expect(try store.transcript(id: record.id) == record)
    #expect(try store.transcript(id: UUID()) == nil)
}

@Test func saveReplacesExistingRecordById() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    var record = makeRecord(rawText: "first draft")
    try store.save(record)
    record.deliveredText = "Second draft."
    record.isCancelled = true
    try store.save(record)

    #expect(try store.allTranscripts().count == 1)
    #expect(try store.transcript(id: record.id) == record)
}

// MARK: - Search

@Test func englishKeywordSearchFindsRecord() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let meeting = makeRecord(rawText: "Team standup meeting notes")
    let other = makeRecord(
        rawText: "Grocery list apples and rice",
        createdAt: Date(timeIntervalSince1970: 1_723_000_500)
    )
    try store.save(meeting)
    try store.save(other)

    let results = try store.search("meeting")
    #expect(results.map(\.id) == [meeting.id])
}

@Test func chineseSubstringSearchFindsRecordViaTrigram() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let record = makeRecord(rawText: "我们周六去爬山吧", language: .chinese)
    try store.save(record)

    // Three characters: served by the trigram FTS index.
    let results = try store.search("去爬山")
    #expect(results.map(\.id) == [record.id])
}

@Test func twoCharacterChineseQueryFindsRecord() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let record = makeRecord(rawText: "我们周六去爬山吧", language: .chinese)
    try store.save(record)

    // Below the trigram minimum: served by the LIKE fallback.
    let results = try store.search("周六")
    #expect(results.map(\.id) == [record.id])
}

@Test func oneCharacterChineseQueryFallsBackToLike() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let record = makeRecord(rawText: "我们周六去爬山吧", language: .chinese)
    let unrelated = makeRecord(
        rawText: "nothing to see here",
        createdAt: Date(timeIntervalSince1970: 1_723_000_500)
    )
    try store.save(record)
    try store.save(unrelated)

    let results = try store.search("山")
    #expect(results.map(\.id) == [record.id])
}

@Test func searchDeduplicatesAcrossIndexes() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    // "hello" matches both the unicode61 and the trigram index.
    let record = makeRecord(rawText: "hello 你好世界")
    try store.save(record)

    let results = try store.search("hello")
    #expect(results.map(\.id) == [record.id])
}

@Test func searchOrdersByCreatedAtDescending() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let older = makeRecord(rawText: "meeting agenda", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeRecord(rawText: "meeting notes", createdAt: Date(timeIntervalSince1970: 2_000))
    try store.save(older)
    try store.save(newer)

    #expect(try store.search("meeting").map(\.id) == [newer.id, older.id])
}

@Test func emptyAndUnmatchedQueriesReturnNothing() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    try store.save(makeRecord(rawText: "Team standup meeting notes"))
    #expect(try store.search("").isEmpty)
    #expect(try store.search("   ").isEmpty)
    #expect(try store.search("zebra").isEmpty)
}

// MARK: - Dictionary CRUD

@Test func dictionaryEntryCrudRoundTrips() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    var entry = DictionaryEntry(
        spoken: "麦门",
        written: "MaiMen",
        languages: [.chinese],
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastAppliedAt: Date(timeIntervalSince1970: 1_700_000_500),
        applyCount: 3
    )
    try store.save(entry)
    #expect(try store.dictionaryEntries() == [entry])
    #expect(try store.dictionaryEntries().first?.matchMode == .phrase)

    entry.written = "麦门!"
    entry.applyCount = 4
    try store.save(entry)
    #expect(try store.dictionaryEntries() == [entry])

    try store.deleteDictionaryEntry(id: entry.id)
    #expect(try store.dictionaryEntries().isEmpty)
}

// MARK: - Profile CRUD

@Test func profileCrudRoundTrips() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    var profile = Profile(
        name: "Email",
        icon: "envelope",
        cleanupEnabled: true,
        promptText: "Rewrite as a polite email.",
        providerOverride: .openAICompatible(name: "LM Studio"),
        formatting: .verbatim,
        ignoresGlobalStyle: true,
        routes: [
            .app(bundleID: "com.apple.mail"),
            .website(hostname: "mail.google.com"),
            .defaultRoute
        ],
        priority: 10,
        languageOverride: .pinned(.chinese)
    )
    try store.save(profile)
    #expect(try store.profiles() == [profile])

    profile.name = "Work Email"
    profile.priority = 20
    try store.save(profile)
    #expect(try store.profiles() == [profile])

    try store.deleteProfile(id: profile.id)
    #expect(try store.profiles().isEmpty)
}

/// A row written by a newer build (an unrecognized `language`) or a mangled
/// JSON column must cost the user that one row, not the whole history list.
@Test func unreadableRowIsSkippedRatherThanFailingTheWholeList() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let good = makeRecord(rawText: "readable", createdAt: Date(timeIntervalSince1970: 1_000))
    let fromTheFuture = makeRecord(
        rawText: "written by a later version", createdAt: Date(timeIntervalSince1970: 2_000)
    )
    try store.save(good)
    try store.save(fromTheFuture)

    // Rewrite one row's language to a value this build does not know.
    try DatabaseQueue(path: path).write { db in
        try db.execute(
            sql: "UPDATE transcript SET language = ? WHERE id = ?",
            arguments: ["xx", fromTheFuture.id.uuidString]
        )
    }

    let all = try store.allTranscripts()
    #expect(all.map(\.id) == [good.id])

    // Search follows the same rule.
    let found = try store.search("readable")
    #expect(found.map(\.id) == [good.id])

    // Asking for that row by id still reports the problem.
    #expect(throws: (any Error).self) { try store.transcript(id: fromTheFuture.id) }
}

/// "Delete All" must remove rows this build cannot decode — they are exactly
/// the ones the user can no longer see or delete individually, while their
/// raw text still sits in the file.
@Test func deleteAllTranscriptsRemovesUndecodableRowsToo() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let visible = makeRecord(rawText: "readable", createdAt: Date(timeIntervalSince1970: 1_000))
    let fromTheFuture = makeRecord(
        rawText: "private dictation", createdAt: Date(timeIntervalSince1970: 2_000)
    )
    try store.save(visible)
    try store.save(fromTheFuture)
    try DatabaseQueue(path: path).write { db in
        try db.execute(
            sql: "UPDATE transcript SET language = ? WHERE id = ?",
            arguments: ["xx", fromTheFuture.id.uuidString]
        )
    }
    // The forged row is invisible to the list query…
    #expect(try store.allTranscripts().count == 1)

    // …but Delete All still takes it.
    #expect(try store.deleteAllTranscripts() == 2)

    let remaining = try DatabaseQueue(path: path).read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript") ?? -1
    }
    #expect(remaining == 0)
}

/// One profile document a newer build wrote (or one mangled document) must
/// not silently discard the user's whole profile set — the app treats a load
/// failure as "fall back to built-ins".
@Test func unreadableProfileRowIsSkippedNotFatal() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let good = Profile(name: "Email")
    try store.save(good)
    try DatabaseQueue(path: path).write { db in
        try db.execute(
            sql: "INSERT INTO profile (id, name, document) VALUES (?, ?, ?)",
            arguments: [UUID().uuidString, "Broken", "not json"]
        )
    }
    #expect(try store.profiles() == [good])
}

/// Same rule for the dictionary: one bad entry must not empty the whole
/// dictionary (the session reads it on every single dictation).
@Test func unreadableDictionaryRowIsSkippedNotFatal() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let good = DictionaryEntry(spoken: "cloud code", written: "Claude Code")
    try store.save(good)
    try DatabaseQueue(path: path).write { db in
        try db.execute(
            sql: "INSERT INTO dictionary_entry (id, document) VALUES (?, ?)",
            arguments: [UUID().uuidString, "{broken"]
        )
    }
    #expect(try store.dictionaryEntries() == [good])
}

#else

@Test func persistenceIsUnsupportedWithoutGRDB() {
    #expect(PersistenceInfo.isSupported == false)
}

#endif
