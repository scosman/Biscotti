import Foundation
import SQLite3

// MARK: - Errors

enum SearchIndexError: Error, LocalizedError {
    case openFailed(String)
    case sqliteError(context: String, message: String)
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(msg): "Failed to open search index: \(msg)"
        case let .sqliteError(ctx, msg): "Search index SQLite error (\(ctx)): \(msg)"
        case let .internalError(msg): "Search index internal error: \(msg)"
        }
    }
}

// MARK: - SearchIndex

/// Manages a SQLite FTS5 full-text search index for meetings.
///
/// The index is a separate SQLite database (not part of the SwiftData store).
/// A single FTS5 table (`meeting_search_index`) holds one column per
/// searchable field, and **stores the source text** so `bm25()` ranking and
/// `snippet()` extraction both work. `meeting_map` is an ordinary table that
/// maps meeting UUIDs to the FTS rowid and carries the effective date used
/// for tie-breaking.
///
/// Storing the text costs roughly the size of the transcript corpus. That is
/// a small fraction of the audio this app already keeps, and it buys two
/// things: real relevance ranking, and search results that need no SwiftData
/// fetch at all (title and snippet both come from this database).
///
/// **Not `Sendable`** -- only accessed from within the `DataStore` actor.
final class SearchIndex {
    /// The underlying SQLite connection handle.
    private var database: OpaquePointer?

    /// Bump to force a full rebuild on the next sync.
    static let schemaVersion = 3

    /// The FTS5 virtual table holding all searchable text.
    static let ftsTable = "meeting_search_index"

    /// Maximum tokens in a generated snippet (FTS5 allows 1...64).
    private static let snippetTokens = 30

    /// Maximum characters of the fallback preview excerpt.
    private static let previewCharacters = 300

    /// Storage configuration.
    enum Storage {
        case onDisk(URL)
        case inMemory
    }

    /// Searchable fields, in **column order**.
    ///
    /// The declaration order defines both the `CREATE VIRTUAL TABLE` column
    /// list and the `bm25()` weight argument order, so the two cannot drift.
    /// Do not reorder without bumping `schemaVersion`.
    enum Field: String, CaseIterable {
        case title, summary, notes, transcript, people, tags

        /// Relative `bm25()` column weight. Higher means a match in this
        /// field contributes more to the score.
        var weight: Double {
            switch self {
            case .title: 3.0
            case .tags: 3.0
            case .summary: 2.0
            case .people: 2.0
            case .notes: 1.0
            case .transcript: 1.0
            }
        }
    }

    /// The FTS column list, in declaration order.
    private static var columnList: String {
        Field.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// The `bm25()` weight arguments, in the same order as `columnList`.
    /// `Double.description` is locale-independent, so this is always
    /// `"3.0, 2.0, ..."` and never a comma decimal separator.
    private static var bm25Weights: String {
        Field.allCases.map { "\($0.weight)" }.joined(separator: ", ")
    }

    /// All field data for a single meeting, ready to be indexed.
    struct MeetingContent {
        let uuid: UUID
        /// Effective date: `startDate ?? createdAt`.
        let effectiveDate: Date
        let title: String
        let summary: String
        let notes: String
        let transcript: String
        let people: String
        let tags: String

        /// The text belonging to a given column.
        ///
        /// Exhaustive by design: adding a `Field` case fails to compile until
        /// its text is supplied here.
        func value(for field: Field) -> String {
            switch field {
            case .title: title
            case .summary: summary
            case .notes: notes
            case .transcript: transcript
            case .people: people
            case .tags: tags
            }
        }

        /// Field values in `Field.allCases` order, for binding.
        ///
        /// Derived from `Field.allCases` -- the same source as `columnList`
        /// and `bm25Weights` -- so a reordering of the enum moves the columns,
        /// the weights and the values together. A hand-written array here
        /// would silently bind text into the wrong columns on reorder.
        var orderedValues: [String] {
            Field.allCases.map(value(for:))
        }
    }

    /// A search result. Everything needed to render a result row comes from
    /// this database -- no SwiftData fetch is required.
    struct RawHit {
        let meetingUUID: UUID
        /// Relevance, higher is better. This is the negated `bm25()` value
        /// (FTS5 returns a negative number where more-negative is better).
        let score: Double
        /// The meeting title, read back from the index.
        let title: String
        /// A context excerpt around the best-matching field, from
        /// `snippet()`. Equals the title when the match is title-only,
        /// because FTS5 then picks the title as the best column.
        let snippet: String
        /// The opening of the meeting's own content (summary, then notes,
        /// then transcript, then people). Used as the second line when
        /// `snippet` only echoes the title, so a result row is never blank
        /// below the title. Empty only for a meeting with no content at all.
        let preview: String
        /// Effective date stored in the side DB at index time.
        let effectiveDate: Date
    }

    init(storage: Storage) throws {
        let path: String = switch storage {
        case let .onDisk(url):
            url.path
        case .inMemory:
            ":memory:"
        }

        var dbPtr: OpaquePointer?
        let status = sqlite3_open_v2(
            path, &dbPtr,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let opened = dbPtr else {
            let msg = dbPtr.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPtr)
            throw SearchIndexError.openFailed(msg)
        }
        database = opened

        // WAL mode for better read performance during writes.
        try execSQL("PRAGMA journal_mode=WAL")
        try initializeOrMigrate()
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    // MARK: - Schema Management

    private func initializeOrMigrate() throws {
        try execSQL("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value BLOB
            )
        """)

        let currentVersion = (try? metaInt("schema_version")) ?? 0
        guard currentVersion != Self.schemaVersion else { return }

        // Schema mismatch or first run -- drop and recreate.
        try dropDataTables()
        try createDataTables()
        try deleteMeta("history_token")
        try setMeta("schema_version", int: Self.schemaVersion)
    }

    private func createDataTables() throws {
        try execSQL("""
            CREATE TABLE IF NOT EXISTS meeting_map (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_uuid TEXT NOT NULL UNIQUE,
                effective_date REAL NOT NULL DEFAULT 0
            )
        """)

        // A plain (content-storing) FTS5 table. Contentless tables cannot
        // support snippet()/highlight(), and this SQLite (3.43) predates
        // contentless_unindexed=1, so the text has to live here.
        try execSQL("""
            CREATE VIRTUAL TABLE IF NOT EXISTS \(Self.ftsTable) \
            USING fts5(\(Self.columnList))
        """)
    }

    private func dropDataTables() throws {
        try execSQL("DROP TABLE IF EXISTS \(Self.ftsTable)")
        try execSQL("DROP TABLE IF EXISTS meeting_map")

        // Tables from schema version <= 2 (one FTS table per field).
        // Harmless no-ops on a fresh database.
        for field in Field.allCases {
            try execSQL("DROP TABLE IF EXISTS fts_\(field.rawValue)")
        }
    }

    // MARK: - Indexing

    /// Indexes a single meeting. Safe to call repeatedly with the same UUID:
    /// the `meeting_map` row is upserted and the FTS row is replaced.
    ///
    /// Wrapped in a transaction so a throw or crash between the `meeting_map`
    /// write and the FTS write cannot leave the two disagreeing.
    func indexMeeting(_ content: MeetingContent) throws {
        let uuidStr = content.uuid.uuidString
        let dateValue = content.effectiveDate.timeIntervalSinceReferenceDate

        try execSQL("BEGIN IMMEDIATE")
        do {
            // Ensure the meeting has a row in meeting_map.
            try execSQL(
                """
                INSERT INTO meeting_map(meeting_uuid, effective_date)
                VALUES (?, ?)
                ON CONFLICT(meeting_uuid) DO UPDATE SET effective_date = excluded.effective_date
                """,
                params: [.text(uuidStr), .double(dateValue)]
            )

            guard let rowid = try queryInt64(
                "SELECT id FROM meeting_map WHERE meeting_uuid = ?",
                params: [.text(uuidStr)]
            ) else {
                throw SearchIndexError.internalError(
                    "Failed to get rowid for meeting \(uuidStr)"
                )
            }

            let placeholders = Array(
                repeating: "?", count: Field.allCases.count
            ).joined(separator: ", ")
            try execSQL(
                """
                INSERT OR REPLACE INTO \(Self.ftsTable)(rowid, \(Self.columnList)) \
                VALUES (?, \(placeholders))
                """,
                params: [.int64(rowid)] + content.orderedValues.map { .text($0) }
            )

            try execSQL("COMMIT")
        } catch {
            try? execSQL("ROLLBACK")
            throw error
        }
    }

    /// Removes a meeting from the index.
    func removeMeeting(uuid: UUID) throws {
        let uuidStr = uuid.uuidString

        // Read-only guard outside the transaction: avoids opening a
        // write transaction for a meeting that is not in the index.
        guard let rowid = try queryInt64(
            "SELECT id FROM meeting_map WHERE meeting_uuid = ?",
            params: [.text(uuidStr)]
        ) else { return }

        try execSQL("BEGIN IMMEDIATE")
        do {
            try execSQL(
                "DELETE FROM \(Self.ftsTable) WHERE rowid = ?",
                params: [.int64(rowid)]
            )
            try execSQL("DELETE FROM meeting_map WHERE id = ?", params: [.int64(rowid)])

            try execSQL("COMMIT")
        } catch {
            try? execSQL("ROLLBACK")
            throw error
        }
    }

    /// Removes all index entries whose UUIDs are not in the given live set.
    func removeStaleEntries(liveUUIDs: Set<UUID>) throws {
        for uuid in try allIndexedUUIDs() where !liveUUIDs.contains(uuid) {
            try removeMeeting(uuid: uuid)
        }
    }

    /// Returns every meeting UUID currently in the index.
    func allIndexedUUIDs() throws -> [UUID] {
        try queryUUIDs("SELECT meeting_uuid FROM meeting_map")
    }

    /// Deletes all indexed data and resets the history token.
    /// The schema version is preserved (no re-migration on next sync).
    func clear() throws {
        try dropDataTables()
        try createDataTables()
        try deleteMeta("history_token")
    }

    /// Number of meetings currently in the index.
    var indexedMeetingCount: Int {
        (try? queryInt64("SELECT COUNT(*) FROM meeting_map", params: []))
            .map(Int.init) ?? 0
    }
}

// MARK: - Search

extension SearchIndex {
    /// Searches the index using prefix + AND semantics.
    ///
    /// `"proj plan"` becomes `"proj"* AND "plan"*` -- a meeting matches only
    /// when every term appears in at least one field. Ranking is FTS5's
    /// `bm25()` with per-column weights (title 3, tags 3, summary 2,
    /// people 2, notes 1, transcript 1), so term frequency, term rarity and
    /// field length all contribute.
    ///
    /// Ordering is total -- `(rank, effective date desc, UUID)` -- and is
    /// applied by SQLite *before* `LIMIT`, so truncation is deterministic at
    /// tie boundaries and the full result set never crosses into Swift.
    func search(query: String, limit: Int) throws -> [RawHit] {
        // Split on ALL whitespace, not just " ". A pasted or tab-separated
        // query would otherwise stay one term, and `fts5Escape` would wrap the
        // embedded whitespace in double quotes -- which FTS5 reads as a
        // *phrase*, requiring the words to be adjacent. That does not fail
        // loudly; it silently returns a different, wrong result set.
        let terms = query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return [] }

        let matchExpr = terms
            .map { "\(fts5Escape($0))*" }
            .joined(separator: " AND ")

        return try queryHits(matchExpr: matchExpr, limit: limit)
    }

    /// The fallback second line: the opening of whatever content the
    /// meeting has, in descending order of usefulness.
    private static var previewExpression: String {
        let table = ftsTable
        let chars = previewCharacters
        let textual: [Field] = [.summary, .notes, .transcript]
        let branches = textual.map { field in
            """
            WHEN length(trim(\(table).\(field.rawValue))) > 0 \
            THEN substr(trim(\(table).\(field.rawValue)), 1, \(chars))
            """
        }.joined(separator: " ")
        return """
            CASE \(branches) \
            WHEN length(trim(\(table).people)) > 0 THEN trim(\(table).people) \
            ELSE '' END
        """
    }

    private func queryHits(matchExpr: String, limit: Int) throws -> [RawHit] {
        let table = Self.ftsTable
        let sql = """
            SELECT m.meeting_uuid, m.effective_date, \
            bm25(\(table), \(Self.bm25Weights)) AS rank, \
            \(table).title, \
            snippet(\(table), -1, '', '', '\u{2026}', \(Self.snippetTokens)), \
            \(Self.previewExpression) \
            FROM \(table) \
            JOIN meeting_map m ON m.id = \(table).rowid \
            WHERE \(table) MATCH ? \
            ORDER BY rank ASC, m.effective_date DESC, m.meeting_uuid ASC \
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare queryHits")
        }
        defer { sqlite3_finalize(stmt) }

        if let prepared = stmt {
            try bindParams(
                prepared, params: [.text(matchExpr), .int64(Int64(limit))]
            )
        }

        var hits: [RawHit] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw sqliteError("step queryHits")
            }
            if let hit = Self.readHit(stmt) { hits.append(hit) }
        }
        return hits
    }

    /// Reads one result row. Returns `nil` for a row whose UUID cannot be
    /// parsed -- that entry is unusable, but it is not a query failure.
    private static func readHit(_ stmt: OpaquePointer?) -> RawHit? {
        guard let uuidCStr = sqlite3_column_text(stmt, 0),
              let uuid = UUID(uuidString: String(cString: uuidCStr))
        else { return nil }

        let text: (Int32) -> String = { column in
            sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
        }

        return RawHit(
            meetingUUID: uuid,
            // bm25() is negative with more-negative meaning a better match.
            // Negate so `score` reads the way its name implies.
            score: -sqlite3_column_double(stmt, 2),
            title: text(3),
            snippet: flattenWhitespace(text(4)),
            preview: flattenWhitespace(text(5)),
            effectiveDate: Date(
                timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)
            )
        )
    }

    /// Collapses every run of whitespace into a single space and trims the
    /// ends.
    ///
    /// The transcript column is segments joined with newlines, so an excerpt
    /// can straddle a segment boundary and carry hard line breaks. Rendered
    /// in a line-limited label those break early, which can push the matched
    /// term out of view entirely -- the excerpt then looks like it does not
    /// contain the search term at all.
    private static func flattenWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - History Token Persistence

extension SearchIndex {
    func setHistoryToken(_ data: Data) throws {
        try setMeta("history_token", blob: data)
    }

    func historyToken() throws -> Data? {
        try metaBlob("history_token")
    }
}

// MARK: - SQLite Helpers (private)

extension SearchIndex {
    private enum Param {
        case text(String)
        case int64(Int64)
        case double(Double)
        case blob(Data)
    }

    /// SQLITE_TRANSIENT tells SQLite to make its own copy of bound data.
    private static let sqliteTransient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    private func execSQL(_ sql: String, params: [Param] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }

        if let prepared = stmt {
            try bindParams(prepared, params: params)
        }

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw sqliteError("step: \(sql)")
        }
    }

    private func queryInt64(_ sql: String, params: [Param]) throws -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }

        if let prepared = stmt {
            try bindParams(prepared, params: params)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func queryUUIDs(_ sql: String) throws -> [UUID] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare queryUUIDs")
        }
        defer { sqlite3_finalize(stmt) }

        // Distinguish DONE from an error. A silent break on error would return
        // a truncated list as success -- and `removeStaleEntries` treats this
        // list as the complete set of indexed meetings, so truncation there
        // leaves stale entries behind with no signal that anything went wrong.
        var uuids: [UUID] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw sqliteError("step queryUUIDs")
            }
            if let cStr = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr))
            {
                uuids.append(uuid)
            }
        }
        return uuids
    }

    private func bindParams(
        _ stmt: OpaquePointer, params: [Param]
    ) throws {
        for (index, param) in params.enumerated() {
            let col = Int32(index + 1)
            let status: Int32 = switch param {
            case let .text(str):
                str.withCString { cStr in
                    sqlite3_bind_text(stmt, col, cStr, -1, Self.sqliteTransient)
                }
            case let .int64(val):
                sqlite3_bind_int64(stmt, col, val)
            case let .double(val):
                sqlite3_bind_double(stmt, col, val)
            case let .blob(data):
                data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(
                        stmt, col, raw.baseAddress,
                        Int32(data.count), Self.sqliteTransient
                    )
                }
            }
            guard status == SQLITE_OK else {
                throw sqliteError("bind param \(col)")
            }
        }
    }

    /// Wraps the current SQLite error message in a `SearchIndexError`.
    private func sqliteError(_ context: String) -> SearchIndexError {
        let msg = database.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
        return .sqliteError(context: context, message: msg)
    }

    /// Escapes a term for use in an FTS5 MATCH expression.
    /// Wrapping in double quotes handles all special characters.
    private func fts5Escape(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - Meta Table

    private func setMeta(_ key: String, int value: Int) throws {
        try setMeta(key, blob: withUnsafeBytes(of: value) { Data($0) })
    }

    private func metaInt(_ key: String) throws -> Int? {
        guard let data = try metaBlob(key),
              data.count == MemoryLayout<Int>.size
        else { return nil }
        return data.withUnsafeBytes { $0.load(as: Int.self) }
    }

    private func setMeta(_ key: String, blob value: Data) throws {
        try execSQL(
            "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)",
            params: [.text(key), .blob(value)]
        )
    }

    private func metaBlob(_ key: String) throws -> Data? {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare metaBlob")
        }
        defer { sqlite3_finalize(stmt) }

        let bindStatus = key.withCString { cStr in
            sqlite3_bind_text(stmt, 1, cStr, -1, Self.sqliteTransient)
        }
        guard bindStatus == SQLITE_OK else {
            throw sqliteError("bind metaBlob")
        }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let ptr = sqlite3_column_blob(stmt, 0)
        else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: ptr, count: count)
    }

    private func deleteMeta(_ key: String) throws {
        try execSQL("DELETE FROM meta WHERE key = ?", params: [.text(key)])
    }
}

// MARK: - Test Helpers

extension SearchIndex {
    /// Deletes the persisted history token from the meta table.
    /// Exposed for tests that need to force a full reconcile.
    func testDeleteHistoryToken() throws {
        try deleteMeta("history_token")
    }

    /// Returns the internal rowid for a meeting UUID, or nil if absent.
    /// Exposed for tests that simulate partial-index corruption.
    func testRowID(for meetingUUID: UUID) throws -> Int64? {
        try queryInt64(
            "SELECT id FROM meeting_map WHERE meeting_uuid = ?",
            params: [.text(meetingUUID.uuidString)]
        )
    }

    /// Deletes the FTS row while leaving the `meeting_map` row in place,
    /// simulating a crash between the two writes in `indexMeeting`.
    /// Exposed for tests only.
    func testDeleteIndexRow(rowid: Int64) throws {
        try execSQL(
            "DELETE FROM \(Self.ftsTable) WHERE rowid = ?",
            params: [.int64(rowid)]
        )
    }
}
