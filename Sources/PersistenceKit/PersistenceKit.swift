import CoreModels
import Foundation

#if canImport(GRDB)
import GRDB

/// Platform capability probe: true where the GRDB-backed store compiles.
public enum PersistenceInfo {
    public static let isSupported: Bool = true
}

/// Errors surfaced by `DatabaseStore` beyond raw database errors.
public enum DatabaseStoreError: Error, Sendable, Equatable {
    case invalidJSON(column: String)
    case corruptRow(id: String)
}

/// Single-database GRDB store for history, dictionary, and profiles
/// (docs/03 §5). Search is dual FTS5 — `unicode61` for Latin keywords and
/// `trigram` for Chinese substrings — with a LIKE fallback for 1–2-character
/// CJK queries that neither tokenizer can serve.
public final class DatabaseStore: Sendable {
    private let dbQueue: DatabaseQueue

    private static let transcriptColumns =
        "id, createdAt, source, language, rawText, deliveredText, durationSeconds, "
        + "targetAppBundleID, targetAppName, profileName, routeKind, cleanup, timings, "
        + "audioPath, isCancelled, importedFilename"

    public init(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
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
                    rawText, deliveredText,
                    content='transcript',
                    tokenize='unicode61'
                )
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcript_fts_tri USING fts5(
                    rawText, deliveredText,
                    content='transcript',
                    tokenize='trigram'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER transcript_after_insert AFTER INSERT ON transcript BEGIN
                    INSERT INTO transcript_fts_latin(rowid, rawText, deliveredText)
                        VALUES (new.rowid, new.rawText, new.deliveredText);
                    INSERT INTO transcript_fts_tri(rowid, rawText, deliveredText)
                        VALUES (new.rowid, new.rawText, new.deliveredText);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER transcript_after_delete AFTER DELETE ON transcript BEGIN
                    INSERT INTO transcript_fts_latin(transcript_fts_latin, rowid, rawText, deliveredText)
                        VALUES ('delete', old.rowid, old.rawText, old.deliveredText);
                    INSERT INTO transcript_fts_tri(transcript_fts_tri, rowid, rawText, deliveredText)
                        VALUES ('delete', old.rowid, old.rawText, old.deliveredText);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER transcript_after_update AFTER UPDATE ON transcript BEGIN
                    INSERT INTO transcript_fts_latin(transcript_fts_latin, rowid, rawText, deliveredText)
                        VALUES ('delete', old.rowid, old.rawText, old.deliveredText);
                    INSERT INTO transcript_fts_tri(transcript_fts_tri, rowid, rawText, deliveredText)
                        VALUES ('delete', old.rowid, old.rawText, old.deliveredText);
                    INSERT INTO transcript_fts_latin(rowid, rawText, deliveredText)
                        VALUES (new.rowid, new.rawText, new.deliveredText);
                    INSERT INTO transcript_fts_tri(rowid, rawText, deliveredText)
                        VALUES (new.rowid, new.rawText, new.deliveredText);
                END
                """)
        }
        try migrator.migrate(queue)
        dbQueue = queue
    }

    // MARK: - Transcripts

    /// Insert or replace by id. Delete-then-insert keeps the external-content
    /// FTS triggers firing deterministically (REPLACE only fires delete
    /// triggers when recursive triggers are enabled).
    public func save(_ record: TranscriptRecord) throws {
        let cleanupJSON = try Self.encodeJSON(record.cleanup, column: "cleanup")
        let timingsJSON = try Self.encodeJSON(record.timings, column: "timings")
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM transcript WHERE id = ?",
                arguments: [record.id.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO transcript (
                        id, createdAt, source, language, rawText, deliveredText,
                        durationSeconds, targetAppBundleID, targetAppName, profileName,
                        routeKind, cleanup, timings, audioPath, isCancelled, importedFilename
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id.uuidString,
                    record.createdAt.timeIntervalSince1970,
                    record.source.rawValue,
                    record.language.rawValue,
                    record.rawText,
                    record.deliveredText,
                    record.durationSeconds,
                    record.targetAppBundleID,
                    record.targetAppName,
                    record.profileName,
                    record.routeKind.rawValue,
                    cleanupJSON,
                    timingsJSON,
                    record.audioPath,
                    record.isCancelled,
                    record.importedFilename
                ]
            )
        }
    }

    /// Fetching one row surfaces the decode failure — the caller asked for
    /// exactly this record and deserves to know it is unreadable.
    public func transcript(id: UUID) throws -> TranscriptRecord? {
        try dbQueue.read { db -> TranscriptRecord? in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT \(Self.transcriptColumns) FROM transcript WHERE id = ?",
                arguments: [id.uuidString]
            )
            return try row.map(Self.record(from:))
        }
    }

    public func allTranscripts() throws -> [TranscriptRecord] {
        try dbQueue.read { db -> [TranscriptRecord] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT \(Self.transcriptColumns) FROM transcript ORDER BY createdAt DESC"
            )
            return Self.decodedRecords(from: rows)
        }
    }

    public func deleteTranscript(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcript WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Search history: Latin FTS first, then trigram FTS, then a LIKE scan for
    /// 1–2-character CJK queries. Results are de-duplicated by id and ordered
    /// by `createdAt` descending (AC-7 covers both scripts).
    public func search(_ query: String) throws -> [TranscriptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return try dbQueue.read { db -> [TranscriptRecord] in
            var seen = Set<UUID>()
            var results: [TranscriptRecord] = []

            func collect(_ rows: [Row]) {
                for record in Self.decodedRecords(from: rows)
                where seen.insert(record.id).inserted {
                    results.append(record)
                }
            }

            // Quote as one FTS5 phrase so user text is never parsed as query syntax.
            let phrase = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""

            collect(try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.transcriptColumns) FROM transcript
                    WHERE rowid IN (
                        SELECT rowid FROM transcript_fts_latin WHERE transcript_fts_latin MATCH ?
                    )
                    """,
                arguments: [phrase]
            ))

            // FTS5's trigram tokenizer needs at least three characters to match.
            if trimmed.count >= 3 {
                collect(try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(Self.transcriptColumns) FROM transcript
                        WHERE rowid IN (
                            SELECT rowid FROM transcript_fts_tri WHERE transcript_fts_tri MATCH ?
                        )
                        """,
                    arguments: [phrase]
                ))
            }

            // 1–2-character CJK queries: unicode61 indexes a Han run as one long
            // token and trigram needs 3+ characters, so scan with LIKE.
            if trimmed.count <= 2, trimmed.containsHanCharacters {
                let escaped = trimmed
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%" + escaped + "%"
                collect(try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(Self.transcriptColumns) FROM transcript
                        WHERE rawText LIKE ? ESCAPE '\\' OR deliveredText LIKE ? ESCAPE '\\'
                        """,
                    arguments: [pattern, pattern]
                ))
            }

            return results.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - Dictionary entries

    public func save(_ entry: DictionaryEntry) throws {
        let document = try Self.encodeJSON(entry, column: "dictionary_entry.document")
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM dictionary_entry WHERE id = ?",
                arguments: [entry.id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO dictionary_entry (id, document) VALUES (?, ?)",
                arguments: [entry.id.uuidString, document]
            )
        }
    }

    public func dictionaryEntries() throws -> [DictionaryEntry] {
        try dbQueue.read { db -> [DictionaryEntry] in
            let documents = try String.fetchAll(
                db,
                sql: "SELECT document FROM dictionary_entry ORDER BY rowid"
            )
            return try documents.map {
                try Self.decodeJSON(DictionaryEntry.self, from: $0, column: "dictionary_entry.document")
            }
        }
    }

    public func deleteDictionaryEntry(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM dictionary_entry WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    // MARK: - Profiles

    public func save(_ profile: Profile) throws {
        let document = try Self.encodeJSON(profile, column: "profile.document")
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM profile WHERE id = ?",
                arguments: [profile.id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO profile (id, name, document) VALUES (?, ?, ?)",
                arguments: [profile.id.uuidString, profile.name, document]
            )
        }
    }

    public func profiles() throws -> [Profile] {
        try dbQueue.read { db -> [Profile] in
            let documents = try String.fetchAll(
                db,
                sql: "SELECT document FROM profile ORDER BY name, rowid"
            )
            return try documents.map {
                try Self.decodeJSON(Profile.self, from: $0, column: "profile.document")
            }
        }
    }

    public func deleteProfile(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM profile WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - JSON columns

    private static func encodeJSON<T: Encodable>(_ value: T, column: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DatabaseStoreError.invalidJSON(column: column)
        }
        return text
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from text: String,
        column: String
    ) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw DatabaseStoreError.invalidJSON(column: column)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DatabaseStoreError.invalidJSON(column: column)
        }
    }

    /// Decodes a list result, dropping rows that will not decode instead of
    /// failing the whole query.
    ///
    /// A row can be unreadable because a newer build wrote an enum case this
    /// one does not know (a `language` from a later version, say) or because
    /// a JSON column got mangled. Either way, one bad row must not make the
    /// user's entire history disappear — everything else in the table is
    /// still perfectly good.
    private static func decodedRecords(from rows: [Row]) -> [TranscriptRecord] {
        rows.compactMap { row in
            do {
                return try record(from: row)
            } catch {
                let id: String? = row["id"]
                print("Vocal: skipping unreadable history row \(id ?? "<unknown>"): \(error)")
                return nil
            }
        }
    }

    private static func record(from row: Row) throws -> TranscriptRecord {
        let idString: String = row["id"]
        guard
            let id = UUID(uuidString: idString),
            let source = TranscriptSource(rawValue: row["source"]),
            let language = Language(rawValue: row["language"]),
            let routeKind = TranscriptRecord.RouteKind(rawValue: row["routeKind"])
        else {
            throw DatabaseStoreError.corruptRow(id: idString)
        }
        let createdAtInterval: Double = row["createdAt"]
        let cleanup = try decodeJSON(CleanupOutcome.self, from: row["cleanup"], column: "cleanup")
        let timings = try decodeJSON(TimingBreakdown.self, from: row["timings"], column: "timings")
        return TranscriptRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: createdAtInterval),
            source: source,
            language: language,
            rawText: row["rawText"],
            deliveredText: row["deliveredText"],
            durationSeconds: row["durationSeconds"],
            targetAppBundleID: row["targetAppBundleID"],
            targetAppName: row["targetAppName"],
            profileName: row["profileName"],
            routeKind: routeKind,
            cleanup: cleanup,
            timings: timings,
            audioPath: row["audioPath"],
            isCancelled: row["isCancelled"],
            importedFilename: row["importedFilename"]
        )
    }
}

#else
/// Non-Apple platforms build without GRDB; SessionKit's `TranscriptStoring`
/// seam is served by in-memory fakes in tests (docs/03 §5).
public enum PersistenceInfo {
    public static let isSupported: Bool = false
}
#endif
