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

// MARK: - FTS surrogate rowid (docs/11 G7)

/// The v1 schema, verbatim, so the migration can be tested against a database
/// shaped exactly like the ones already in the field.
private func makeV1Database(at path: String) throws -> DatabaseQueue {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE transcript (
                id TEXT PRIMARY KEY NOT NULL,
                createdAt DOUBLE NOT NULL,
                source TEXT NOT NULL,
                language TEXT NOT NULL,
                rawText TEXT NOT NULL,
                deliveredText TEXT NOT NULL,
                durationSeconds DOUBLE NOT NULL,
                targetAppBundleID TEXT,
                targetAppName TEXT,
                profileName TEXT NOT NULL,
                routeKind TEXT NOT NULL,
                cleanup TEXT NOT NULL,
                timings TEXT NOT NULL,
                audioPath TEXT,
                isCancelled INTEGER NOT NULL DEFAULT 0,
                importedFilename TEXT
            )
            """)
        try db.execute(sql: """
            CREATE TABLE dictionary_entry (
                id TEXT PRIMARY KEY NOT NULL,
                document TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE profile (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                document TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE transcript_fts_latin USING fts5(
                rawText, deliveredText, content='transcript', tokenize='unicode61')
            """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE transcript_fts_tri USING fts5(
                rawText, deliveredText, content='transcript', tokenize='trigram')
            """)
        try db.execute(sql: """
            CREATE TRIGGER transcript_after_insert AFTER INSERT ON transcript BEGIN
                INSERT INTO transcript_fts_latin(rowid, rawText, deliveredText)
                    VALUES (new.rowid, new.rawText, new.deliveredText);
                INSERT INTO transcript_fts_tri(rowid, rawText, deliveredText)
                    VALUES (new.rowid, new.rawText, new.deliveredText);
            END
            """)
        // GRDB records applied migrations in this table; naming v1 as already
        // applied is what makes the store treat this file as a v1 database
        // instead of creating the schema from scratch.
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
    }
    return queue
}

@Test func searchSurvivesAVacuum() throws {
    // The G7 corruption scenario: FTS entries keyed on an implicit rowid that
    // VACUUM is free to renumber. With the v2 surrogate key the numbers are
    // data, so the index still points at the right rows afterwards.
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let first = makeRecord(rawText: "quarterly roadmap review")
    let second = makeRecord(rawText: "dentist appointment tuesday")
    let third = makeRecord(rawText: "周六去爬山吗")
    try store.save(first)
    try store.save(second)
    try store.save(third)
    // Deleting first makes VACUUM actually rebuild — a file with no free pages
    // would renumber nothing and the test would pass vacuously.
    try store.deleteTranscript(id: first.id)

    try store.vacuum()

    #expect(try store.search("dentist").map(\.id) == [second.id])
    #expect(try store.search("爬山").map(\.id) == [third.id])
    #expect(try store.search("roadmap").isEmpty)
    #expect(try store.allTranscripts().count == 2)
}

@Test func transcriptRowidIsAnIntegerPrimaryKey() throws {
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    _ = store

    let queue = try DatabaseQueue(path: path)
    let sql: String? = try queue.read { db in
        try String.fetchOne(
            db, sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='transcript'"
        )
    }
    // An INTEGER PRIMARY KEY column *is* the rowid, which is what makes the
    // numbering stable across a rebuild.
    #expect(sql?.contains("INTEGER PRIMARY KEY") == true)
}

@Test func rowidsAreNotReusedAfterDeletion() throws {
    // AUTOINCREMENT: a new transcript must never land on a deleted row's
    // rowid, where it could inherit a stale FTS entry.
    let (store, path) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let first = makeRecord(rawText: "first take")
    try store.save(first)
    let firstSeq: Int64? = try DatabaseQueue(path: path).read { db in
        try Int64.fetchOne(db, sql: "SELECT seq FROM transcript WHERE id = ?",
                           arguments: [first.id.uuidString])
    }
    try store.deleteTranscript(id: first.id)

    let second = makeRecord(rawText: "second take")
    try store.save(second)
    let secondSeq: Int64? = try DatabaseQueue(path: path).read { db in
        try Int64.fetchOne(db, sql: "SELECT seq FROM transcript WHERE id = ?",
                           arguments: [second.id.uuidString])
    }

    #expect(firstSeq != nil)
    #expect(secondSeq != nil)
    #expect(secondSeq != firstSeq)
    #expect(try store.search("second").map(\.id) == [second.id])
    #expect(try store.search("first").isEmpty)
}

@Test func migratingAV1DatabasePreservesHistoryAndSearch() throws {
    // The owner's Mac already holds a v1 database. Opening it with this build
    // must keep every row and leave search working.
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("vocal-db-v1-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let ids = [UUID(), UUID(), UUID()]
    let texts = ["standup notes for monday", "ကျွန်တော် ထမင်းစားပြီ", "周六去爬山吗"]
    do {
        let queue = try makeV1Database(at: path)
        try queue.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO transcript (
                            id, createdAt, source, language, rawText, deliveredText,
                            durationSeconds, profileName, routeKind, cleanup, timings, isCancelled
                        ) VALUES (?, ?, 'dictation', 'en', ?, ?, 2.5, 'Default', 'defaultRoute',
                                  ?, ?, 0)
                        """,
                    arguments: [
                        id.uuidString,
                        Double(1_723_000_000 + index),
                        texts[index],
                        texts[index],
                        #"{"skipped":{"reason":"masterSwitchOff"}}"#,
                        #"{"captureSeconds":2.5,"transcriptionSeconds":0.5,"dictionarySeconds":0.1,"cleanupSeconds":0,"deliverySeconds":0.1}"#
                    ]
                )
            }
        }
    }

    // Opening runs the v2 migration.
    let store = try DatabaseStore(path: path)

    #expect(try store.allTranscripts().count == 3)
    #expect(Set(try store.allTranscripts().map(\.rawText)) == Set(texts))
    // Search works against the rebuilt indexes, in every script.
    #expect(try store.search("standup").map(\.id) == [ids[0]])
    #expect(try store.search("ထမင်း").map(\.id) == [ids[1]])
    #expect(try store.search("爬山").map(\.id) == [ids[2]])
    // And still works after the rebuild that used to corrupt it.
    try store.vacuum()
    #expect(try store.search("standup").map(\.id) == [ids[0]])
    #expect(try store.allTranscripts().count == 3)
}


#else

@Test func persistenceIsUnsupportedWithoutGRDB() {
    #expect(PersistenceInfo.isSupported == false)
}

#endif
