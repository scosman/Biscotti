import Foundation
import os
import SQLite3

// Read-only SQLite access to the SwiftData store for transcript-segment search.
//
// This opens a **separate read-only connection** to the same SQLite file that
// SwiftData writes. Core Data does not block read queries, so this is safe as
// long as we never write through this path.
//
// **Why raw SQL?** SwiftData's object materialization (faulting every segment
// into a managed object) dominates search cost: ~39 s at 5 000 meetings.
// A direct `LIKE` scan over the same file takes ~137 ms (288x faster).
// See `specs/research/search/README.md` for the full benchmark.
//
// **Schema coupling:** Core Data names a foreign key on the child table
// `Z<parent entity's Z_ENT><parent's relationship name, uppercased>` -- e.g.
// `Z7SEGMENTS`, `Z4TRANSCRIPTS`. Those numeric prefixes are entity indices that
// shift when the data model changes, so **nothing here is hardcoded**: entity
// numbers are read from Core Data's own `Z_PRIMARYKEY` registry, the derived
// names are verified against `pragma_table_info`, and the SQL is built from
// what was actually found. If resolution fails we degrade gracefully (drop the
// segment contribution, log). A gating CI test (`SchemaAssertionTests`) also
// guards against silent breakage.
//
// **`LIKE` semantics differ from `localizedStandardContains`.** SQLite `LIKE`
// is ASCII-case-insensitive only and does no diacritic folding, so "cafe"
// will not match "café". This is a deliberate product tradeoff.

private let logger = Logger(
    subsystem: "net.scosman.biscotti", category: "SQLiteSegmentSearch"
)

// MARK: - Public search entry point

/// Opens a read-only connection and resolves the schema for transcript search.
/// Returns nil (and logs) if the store is in-memory or resolution fails.
/// Callers that search multiple terms should call this once and pass the result
/// to `ReadOnlySQLiteDB.searchSegments(term:schema:)` per term.
func openTranscriptSearchConnection(
    storeFileURL: URL?
) -> (database: ReadOnlySQLiteDB, schema: ResolvedSearchSchema)? {
    guard let storeFileURL else { return nil }
    do {
        let database = try ReadOnlySQLiteDB(path: storeFileURL.path)
        let schema = try ResolvedSearchSchema(database: database)
        return (database, schema)
    } catch {
        logger.error("Transcript search connection failed: \(error)")
        return nil
    }
}

// MARK: - Read-only SQLite wrapper

/// Minimal read-only SQLite3 wrapper. Opens in `SQLITE_OPEN_READONLY` mode
/// so it cannot mutate the store even if a bug passes a write statement.
final class ReadOnlySQLiteDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var pointer: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let opened = pointer else {
            let msg = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let pointer { sqlite3_close(pointer) }
            throw SQLiteSegmentSearchError.openFailed(resultCode: openResult, message: msg)
        }
        handle = opened
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// Searches segments for `term` using a pre-resolved schema.
    /// Escapes LIKE metacharacters (`%`, `_`, `\`) so they are treated as
    /// literal characters -- matching `localizedStandardContains` semantics.
    func searchSegments(term: String, schema: ResolvedSearchSchema) throws -> Set<UUID> {
        // Escape LIKE metacharacters: backslash first (so we don't double-escape).
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let likePattern = "%\(escaped)%"

        let sql = """
        SELECT DISTINCT hex(m.ZID)
        FROM   "\(schema.segmentTable)" s
        JOIN   "\(schema.transcriptTable)" t ON s."\(schema.segmentToTranscriptFK)" = t.Z_PK
        JOIN   "\(schema.meetingTable)" m ON t."\(schema.transcriptToMeetingFK)" = m.Z_PK
        WHERE  s.ZTEXT LIKE ? ESCAPE '\\'
          AND  t.ZID = m.ZPREFERREDTRANSCRIPTID
        """

        var stmt: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteSegmentSearchError.prepareFailed(message: msg)
        }
        defer { sqlite3_finalize(prepared) }

        sqlite3_bind_text(prepared, 1, likePattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var uuids: Set<UUID> = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            if let cText = sqlite3_column_text(prepared, 0) {
                let hex = String(cString: cText)
                if let uuid = uuid(fromHex: hex) {
                    uuids.insert(uuid)
                }
            }
        }
        return uuids
    }

    /// Returns the column names for a given table (via `PRAGMA table_info`).
    func columnNames(table: String) throws -> [String] {
        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteSegmentSearchError.prepareFailed(message: msg)
        }
        defer { sqlite3_finalize(prepared) }

        var names: [String] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            // Column 1 of PRAGMA table_info is the column name.
            if let cText = sqlite3_column_text(prepared, 1) {
                names.append(String(cString: cText))
            }
        }
        return names
    }

    /// Reads Core Data's entity registry from `Z_PRIMARYKEY`.
    /// Returns a map of entity name to its catalog entry.
    func entityRegistry() throws -> [String: EntityEntry] {
        let sql = "SELECT Z_ENT, Z_NAME, Z_SUPER FROM Z_PRIMARYKEY"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteSegmentSearchError.prepareFailed(message: msg)
        }
        defer { sqlite3_finalize(prepared) }

        var registry: [String: EntityEntry] = [:]
        while sqlite3_step(prepared) == SQLITE_ROW {
            let entityNumber = sqlite3_column_int(prepared, 0)
            guard let cName = sqlite3_column_text(prepared, 1) else { continue }
            let name = String(cString: cName)
            // sqlite3_column_int returns 0 for NULL, matching "no inheritance".
            let superEntity = sqlite3_column_int(prepared, 2)
            registry[name] = EntityEntry(
                entityNumber: entityNumber, superEntity: superEntity
            )
        }
        return registry
    }

    /// Builds a `{tableName: Set<columnName>}` catalog from `sqlite_master`
    /// joined with `pragma_table_info` (table-valued function, SQLite 3.16+).
    func fullColumnCatalog() throws -> [String: Set<String>] {
        let sql = """
        SELECT m.name AS table_name, p.name AS column_name
        FROM sqlite_master AS m
        JOIN pragma_table_info(m.name) AS p
        WHERE m.type = 'table'
        """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteSegmentSearchError.prepareFailed(message: msg)
        }
        defer { sqlite3_finalize(prepared) }

        var catalog: [String: Set<String>] = [:]
        while sqlite3_step(prepared) == SQLITE_ROW {
            guard let cTable = sqlite3_column_text(prepared, 0),
                  let cColumn = sqlite3_column_text(prepared, 1) else { continue }
            let tableName = String(cString: cTable)
            let columnName = String(cString: cColumn)
            catalog[tableName, default: []].insert(columnName)
        }
        return catalog
    }

    // MARK: - Meeting date projection

    /// Returns date-only projections of all meetings: ID -> (startDate, createdAt).
    /// Used by `assembleHits` to sort+truncate broad queries without materializing
    /// SwiftData objects. Titles are deliberately excluded — they come from SwiftData
    /// after truncation so displayed data is always fresh (not stale from a second
    /// connection that misses unsaved changes).
    ///
    /// Core Data stores dates as `Double` seconds since the Foundation reference
    /// date (2001-01-01 00:00:00 UTC).
    func meetingDateProjections() throws -> [UUID: MeetingDateProjection] {
        // These are entity/attribute column names, not entity-number-prefixed FK
        // columns -- they are stable across model changes. SchemaAssertionTests
        // guards their presence on every CI run.
        let sql = "SELECT hex(ZID), ZSTARTDATE, ZCREATEDAT FROM ZMEETING"
        var stmt: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let prepared = stmt else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteSegmentSearchError.prepareFailed(message: msg)
        }
        defer { sqlite3_finalize(prepared) }

        var result: [UUID: MeetingDateProjection] = [:]
        // Pre-size for a typical library; harmless if smaller.
        result.reserveCapacity(5000)
        while sqlite3_step(prepared) == SQLITE_ROW {
            guard let hexCStr = sqlite3_column_text(prepared, 0) else { continue }
            let hex = String(cString: hexCStr)
            guard let id = uuid(fromHex: hex) else { continue }

            let startDate: Date? = if sqlite3_column_type(prepared, 1) != SQLITE_NULL {
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(prepared, 1))
            } else {
                nil
            }

            // createdAt is non-optional in the model, so NULL is unlikely. Use
            // distantPast as a deterministic fallback that sorts broken rows last.
            let createdAt = if sqlite3_column_type(prepared, 2) != SQLITE_NULL {
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(prepared, 2))
            } else {
                Date.distantPast
            }

            result[id] = MeetingDateProjection(startDate: startDate, createdAt: createdAt)
        }
        return result
    }
}

// MARK: - Entity Registry Entry

/// An entry from Core Data's `Z_PRIMARYKEY` catalog table.
struct EntityEntry {
    let entityNumber: Int32
    /// `Z_SUPER` value. Zero means no entity inheritance.
    let superEntity: Int32
}

// MARK: - Schema Resolution

/// Resolved Core Data schema for the transcript-segment search query.
///
/// FK column names contain entity indices that shift when the model changes.
/// This struct reads Core Data's own catalog (`Z_PRIMARYKEY` and
/// `pragma_table_info`) to derive and verify every identifier dynamically,
/// rather than hardcoding values like `Z7SEGMENTS` or `Z4TRANSCRIPTS`.
struct ResolvedSearchSchema {
    let meetingTable: String
    let transcriptTable: String
    let segmentTable: String
    let segmentToTranscriptFK: String
    let transcriptToMeetingFK: String

    /// Resolves the schema from the open database, or throws on any mismatch
    /// so the caller can degrade gracefully.
    init(database: ReadOnlySQLiteDB) throws {
        let registry = try database.entityRegistry()

        let meetingEntry = try Self.lookupEntity("Meeting", in: registry)
        let transcriptEntry = try Self.lookupEntity("TranscriptRecord", in: registry)
        _ = try Self.lookupEntity("TranscriptSegmentRecord", in: registry)

        // Table names: "Z" + uppercased entity name (Core Data convention).
        meetingTable = Self.tableName(for: "Meeting")
        transcriptTable = Self.tableName(for: "TranscriptRecord")
        segmentTable = Self.tableName(for: "TranscriptSegmentRecord")

        // FK on child = "Z" + parent's Z_ENT + parent's relationship name uppercased.
        let derivedSegFK = "Z\(transcriptEntry.entityNumber)SEGMENTS"
        let derivedTxFK = "Z\(meetingEntry.entityNumber)TRANSCRIPTS"

        let catalog = try database.fullColumnCatalog()
        try Self.requireColumn(derivedSegFK, inTable: segmentTable, catalog: catalog)
        try Self.requireColumn("ZTEXT", inTable: segmentTable, catalog: catalog)
        try Self.requireColumn(derivedTxFK, inTable: transcriptTable, catalog: catalog)
        try Self.requireColumn("ZID", inTable: transcriptTable, catalog: catalog)
        try Self.requireColumn("ZID", inTable: meetingTable, catalog: catalog)
        try Self.requireColumn("ZPREFERREDTRANSCRIPTID", inTable: meetingTable, catalog: catalog)

        segmentToTranscriptFK = derivedSegFK
        transcriptToMeetingFK = derivedTxFK
    }

    /// Looks up an entity in the registry and rejects entity inheritance.
    private static func lookupEntity(
        _ name: String, in registry: [String: EntityEntry]
    ) throws -> EntityEntry {
        guard let entry = registry[name] else {
            throw SQLiteSegmentSearchError.schemaResolutionFailed(
                reason: "Entity '\(name)' not found in Z_PRIMARYKEY"
            )
        }
        guard entry.superEntity == 0 else {
            throw SQLiteSegmentSearchError.schemaResolutionFailed(
                reason: "Entity '\(name)' uses inheritance (Z_SUPER=\(entry.superEntity))"
            )
        }
        return entry
    }

    /// Verifies a column exists in the catalog, or throws for graceful degradation.
    private static func requireColumn(
        _ column: String, inTable table: String, catalog: [String: Set<String>]
    ) throws {
        guard let columns = catalog[table], columns.contains(column) else {
            throw SQLiteSegmentSearchError.schemaResolutionFailed(
                reason: "Column '\(column)' not found in table '\(table)'"
            )
        }
    }

    /// Derives the Core Data table name from an entity name.
    private static func tableName(for entityName: String) -> String {
        "Z" + entityName.uppercased()
    }
}

// MARK: - Meeting Date Projection

/// Date-only row returned by `meetingDateProjections()`.
/// Titles are excluded — see the method's doc comment for rationale.
struct MeetingDateProjection {
    let startDate: Date?
    let createdAt: Date
    var effectiveDate: Date {
        startDate ?? createdAt
    }
}

// MARK: - Errors

enum SQLiteSegmentSearchError: Error {
    case openFailed(resultCode: Int32, message: String)
    case prepareFailed(message: String)
    case schemaResolutionFailed(reason: String)
}

// MARK: - UUID hex parsing

/// Parses a 32-character uppercase hex string (as produced by SQLite `hex()`)
/// into a `UUID`. Returns nil on malformed input.
private func uuid(fromHex hex: String) -> UUID? {
    guard hex.count == 32 else { return nil }
    let chars = hex
    let start = chars.startIndex
    // Format: 8-4-4-4-12
    let formatted = "\(chars[start ..< chars.index(start, offsetBy: 8)])"
        + "-\(chars[chars.index(start, offsetBy: 8) ..< chars.index(start, offsetBy: 12)])"
        + "-\(chars[chars.index(start, offsetBy: 12) ..< chars.index(start, offsetBy: 16)])"
        + "-\(chars[chars.index(start, offsetBy: 16) ..< chars.index(start, offsetBy: 20)])"
        + "-\(chars[chars.index(start, offsetBy: 20) ..< chars.index(start, offsetBy: 32)])"
    return UUID(uuidString: formatted)
}
