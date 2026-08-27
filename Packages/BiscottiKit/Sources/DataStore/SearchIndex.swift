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
/// It uses `content=''` (contentless) with `contentless_delete=1` so no copy
/// of the source text is stored -- only the reverse index and row IDs.
///
/// Each searchable field gets its own FTS5 table, enabling per-field match
/// detection and weighted scoring without custom FTS5 auxiliary functions.
///
/// **Not `Sendable`** -- only accessed from within the `DataStore` actor.
final class SearchIndex {
    /// The underlying SQLite connection handle.
    private var database: OpaquePointer?

    /// Bump to force a full rebuild on the next sync.
    static let schemaVersion = 2

    /// Storage configuration.
    enum Storage {
        case onDisk(URL)
        case inMemory
    }

    /// Searchable fields with their weights and `SearchField` mappings.
    enum Field: String, CaseIterable {
        case title, summary, notes, transcript, people, tags

        var weight: Int {
            switch self {
            case .title: 3
            case .tags: 3
            case .summary: 2
            case .people: 2
            case .notes: 1
            case .transcript: 1
            }
        }

        var searchField: SearchField {
            switch self {
            case .title: .title
            case .tags: .tags
            case .summary: .summary
            case .people: .people
            case .notes: .notes
            case .transcript: .transcript
            }
        }
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
    }

    /// Raw search result before meeting metadata (title, date) is resolved.
    struct RawHit {
        let meetingUUID: UUID
        let score: Int
        let fields: Set<SearchField>
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

        for field in Field.allCases {
            try execSQL("""
                CREATE VIRTUAL TABLE IF NOT EXISTS fts_\(field.rawValue) \
                USING fts5(text, content='', contentless_delete=1)
            """)
        }
    }

    private func dropDataTables() throws {
        for field in Field.allCases {
            try execSQL("DROP TABLE IF EXISTS fts_\(field.rawValue)")
        }
        try execSQL("DROP TABLE IF EXISTS meeting_map")
    }

    // MARK: - Indexing

    /// Indexes a single meeting. Uses INSERT OR REPLACE so calling this
    /// repeatedly with the same UUID is safe and self-correcting.
    ///
    /// Wrapped in a transaction so a throw or crash mid-write cannot
    /// leave the meeting half-indexed (e.g. title present but transcript
    /// missing). Without the transaction, a crash leaves a transient
    /// inconsistency until the next sync revisits the meeting.
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

            let fieldValues: [(Field, String)] = [
                (.title, content.title), (.summary, content.summary),
                (.notes, content.notes), (.transcript, content.transcript),
                (.people, content.people), (.tags, content.tags)
            ]

            for (field, text) in fieldValues {
                try execSQL(
                    "INSERT OR REPLACE INTO fts_\(field.rawValue)(rowid, text) VALUES (?, ?)",
                    params: [.int64(rowid), .text(text)]
                )
            }

            try execSQL("COMMIT")
        } catch {
            try? execSQL("ROLLBACK")
            throw error
        }
    }

    /// Removes a meeting from the index.
    ///
    /// Wrapped in a transaction for consistency with `indexMeeting` (the
    /// same atomicity argument applies) and to collapse 7 WAL commits
    /// into 1 -- relevant when a reconcile purges many stale entries.
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
            for field in Field.allCases {
                try execSQL(
                    "DELETE FROM fts_\(field.rawValue) WHERE rowid = ?",
                    params: [.int64(rowid)]
                )
            }
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
    // TODO: Each term currently runs 6 queries (one per FTS table).
    // Consider a UNION ALL query across tables per term, or short-
    // circuiting once top-N results stabilize, if profiling shows
    // search latency as a bottleneck.

    /// Searches the index using prefix + AND semantics.
    ///
    /// `"proj plan"` becomes `"proj"* AND "plan"*` -- a meeting matches only
    /// when every term appears in at least one field. The score is the sum of
    /// per-term, per-field weights (title 3, tags 3, summary 2, people 2,
    /// notes 1, transcript 1).
    func search(query: String, limit: Int) throws -> [RawHit] {
        let terms = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return [] }

        // Per-rowid accumulator.
        struct Accumulator {
            var score: Int = 0
            var fields: Set<SearchField> = []
            var termsMatched: Set<Int> = []
        }

        var accumulators: [Int64: Accumulator] = [:]

        for (termIndex, term) in terms.enumerated() {
            let matchExpr = "\(fts5Escape(term))*"

            for field in Field.allCases {
                let sql = """
                    SELECT rowid FROM fts_\(field.rawValue) \
                    WHERE fts_\(field.rawValue) MATCH ?
                """
                let rowids = try queryRowIDs(sql: sql, param: matchExpr)

                for rowid in rowids {
                    var acc = accumulators[rowid, default: Accumulator()]
                    acc.score += field.weight
                    acc.fields.insert(field.searchField)
                    acc.termsMatched.insert(termIndex)
                    accumulators[rowid] = acc
                }
            }
        }

        // AND across terms: keep only meetings matching ALL terms.
        let termCount = terms.count
        let passing = accumulators.filter { $0.value.termsMatched.count == termCount }

        // Resolve rowids to UUIDs and effective dates.
        var results: [RawHit] = []
        for (rowid, acc) in passing {
            if let (uuid, date) = try lookupUUIDAndDate(rowid: rowid) {
                results.append(RawHit(
                    meetingUUID: uuid, score: acc.score,
                    fields: acc.fields, effectiveDate: date
                ))
            }
        }

        // Total ordering: score desc, date desc, UUID for determinism.
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.effectiveDate != rhs.effectiveDate {
                return lhs.effectiveDate > rhs.effectiveDate
            }
            return lhs.meetingUUID.uuidString < rhs.meetingUUID.uuidString
        }
        return Array(results.prefix(limit))
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

    private func queryRowIDs(sql: String, param: String) throws -> [Int64] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }

        let bindStatus = param.withCString { cStr in
            sqlite3_bind_text(stmt, 1, cStr, -1, Self.sqliteTransient)
        }
        guard bindStatus == SQLITE_OK else {
            throw sqliteError("bind: \(sql)")
        }

        var rowids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowids.append(sqlite3_column_int64(stmt, 0))
        }
        return rowids
    }

    private func queryUUIDs(_ sql: String) throws -> [UUID] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare queryUUIDs")
        }
        defer { sqlite3_finalize(stmt) }

        var uuids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr))
            {
                uuids.append(uuid)
            }
        }
        return uuids
    }

    private func lookupUUIDAndDate(rowid: Int64) throws -> (UUID, Date)? {
        var stmt: OpaquePointer?
        let sql = "SELECT meeting_uuid, effective_date FROM meeting_map WHERE id = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError("prepare lookupUUIDAndDate")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_int64(stmt, 1, rowid) == SQLITE_OK else {
            throw sqliteError("bind lookupUUIDAndDate")
        }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0)
        else { return nil }
        guard let uuid = UUID(uuidString: String(cString: cStr)) else { return nil }
        let dateInterval = sqlite3_column_double(stmt, 1)
        let date = Date(timeIntervalSinceReferenceDate: dateInterval)
        return (uuid, date)
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

    /// Deletes a single FTS row for a field, simulating a crash
    /// mid-indexMeeting. Exposed for tests only.
    func testDeleteFTSRow(field: Field, rowid: Int64) throws {
        try execSQL(
            "DELETE FROM fts_\(field.rawValue) WHERE rowid = ?",
            params: [.int64(rowid)]
        )
    }
}
