import Foundation
import SQLite3

nonisolated private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor FolderIndexDatabase {
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DatabaseError.open }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA busy_timeout = 3000")
        // sqlite3_prepare_v2 prepares one statement at a time. Keep migrations
        // discrete so an existing partial database is completed on next launch.
        try execute("CREATE TABLE IF NOT EXISTS search_roots (id TEXT PRIMARY KEY, display_name TEXT NOT NULL, last_known_path TEXT NOT NULL, bookmark_data BLOB, volume_uuid TEXT, enabled INTEGER NOT NULL, include_hidden INTEGER NOT NULL, last_full_scan_at REAL, created_at REAL NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS folders (id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, relative_path TEXT NOT NULL, parent_relative_path TEXT, name TEXT NOT NULL, normalized_name TEXT NOT NULL, normalized_path TEXT NOT NULL, resource_identifier BLOB, last_seen_at REAL NOT NULL, UNIQUE(root_id, relative_path), FOREIGN KEY(root_id) REFERENCES search_roots(id) ON DELETE CASCADE)")
        try execute("CREATE INDEX IF NOT EXISTS folders_root_parent ON folders(root_id, parent_relative_path)")
        try execute("CREATE INDEX IF NOT EXISTS folders_name ON folders(normalized_name)")
        try execute("CREATE INDEX IF NOT EXISTS folders_path ON folders(normalized_path)")
        try execute("CREATE TABLE IF NOT EXISTS pending_reconciliations (id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, relative_path TEXT NOT NULL, recursive INTEGER NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, UNIQUE(root_id, relative_path))")
    }

    deinit { if let db { sqlite3_close(db) } }

    func roots() throws -> [(SearchRoot, Date?)] {
        let statement = try prepare("SELECT id, display_name, last_known_path, bookmark_data, volume_uuid, enabled, include_hidden, created_at, last_full_scan_at FROM search_roots ORDER BY created_at")
        defer { sqlite3_finalize(statement) }
        var output: [(SearchRoot, Date?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = string(statement, 0), let id = UUID(uuidString: idText), let name = string(statement, 1), let path = string(statement, 2) else { continue }
            let bookmark = blob(statement, 3)
            let volume = string(statement, 4)
            let enabled = sqlite3_column_int(statement, 5) != 0
            let hidden = sqlite3_column_int(statement, 6) != 0
            let created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let last = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            output.append((SearchRoot(id: id, displayName: name, lastKnownPath: path, bookmarkData: bookmark, volumeUUID: volume, isEnabled: enabled, includeHiddenFolders: hidden, addedAt: created), last))
        }
        return output
    }

    func saveRoot(_ root: SearchRoot) throws {
        let sql = "INSERT INTO search_roots (id,display_name,last_known_path,bookmark_data,volume_uuid,enabled,include_hidden,created_at) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,last_known_path=excluded.last_known_path,bookmark_data=excluded.bookmark_data,volume_uuid=excluded.volume_uuid,enabled=excluded.enabled,include_hidden=excluded.include_hidden"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        bind(root.id.uuidString, to: statement, at: 1); bind(root.displayName, to: statement, at: 2); bind(root.lastKnownPath, to: statement, at: 3); bind(root.bookmarkData, to: statement, at: 4); bind(root.volumeUUID, to: statement, at: 5); sqlite3_bind_int(statement, 6, root.isEnabled ? 1 : 0); sqlite3_bind_int(statement, 7, root.includeHiddenFolders ? 1 : 0); sqlite3_bind_double(statement, 8, root.addedAt.timeIntervalSince1970)
        try step(statement)
    }

    func removeRoot(_ id: UUID) throws { try transaction { try execute("DELETE FROM search_roots WHERE id = ?", [id.uuidString]) } }
    func folderCount(rootID: UUID) throws -> Int { try scalarInt("SELECT COUNT(*) FROM folders WHERE root_id = ?", [rootID.uuidString]) }

    func beginScan(rootID: UUID, stamp: Double) throws { try execute("UPDATE folders SET last_seen_at = 0 WHERE root_id = ?", [rootID.uuidString]) }

    func upsert(_ folders: [IndexedFolder], rootID: UUID, stamp: Double) throws {
        try transaction {
            let statement = try prepare("INSERT INTO folders (root_id,relative_path,parent_relative_path,name,normalized_name,normalized_path,resource_identifier,last_seen_at) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(root_id,relative_path) DO UPDATE SET parent_relative_path=excluded.parent_relative_path,name=excluded.name,normalized_name=excluded.normalized_name,normalized_path=excluded.normalized_path,resource_identifier=excluded.resource_identifier,last_seen_at=excluded.last_seen_at")
            defer { sqlite3_finalize(statement) }
            for folder in folders {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(rootID.uuidString, to: statement, at: 1); bind(folder.relativePath, to: statement, at: 2); bind(folder.parentRelativePath, to: statement, at: 3); bind(folder.name, to: statement, at: 4); bind(folder.normalizedName, to: statement, at: 5); bind(folder.normalizedPath, to: statement, at: 6); bind(folder.resourceIdentifier, to: statement, at: 7); sqlite3_bind_double(statement, 8, stamp)
                try step(statement)
            }
        }
    }

    /// Deletion is intentionally delayed until a complete, successful scan has read every directory.
    func finishScan(rootID: UUID, stamp: Double) throws {
        try transaction {
            try execute("DELETE FROM folders WHERE root_id = ? AND last_seen_at != ?", [rootID.uuidString, stamp])
            try execute("UPDATE search_roots SET last_full_scan_at = ? WHERE id = ?", [stamp, rootID.uuidString])
        }
    }

    func beginReconciliation(rootID: UUID, relativePath: String, stamp: Double) throws {
        let predicate = subtreePredicate(relativePath)
        try execute("UPDATE folders SET last_seen_at = 0 WHERE root_id = ? AND \(predicate.sql)", [rootID.uuidString] + predicate.values)
    }

    func finishReconciliation(rootID: UUID, relativePath: String, stamp: Double) throws {
        let predicate = subtreePredicate(relativePath)
        try execute("DELETE FROM folders WHERE root_id = ? AND \(predicate.sql) AND last_seen_at != ?", [rootID.uuidString] + predicate.values + [stamp])
    }

    /// A read failure is neither a deletion nor proof that the directory is empty.
    func preserveUnreadableSubtree(rootID: UUID, relativePath: String, stamp: Double) throws {
        let predicate = subtreePredicate(relativePath)
        try execute("UPDATE folders SET last_seen_at = ? WHERE root_id = ? AND \(predicate.sql)", [stamp, rootID.uuidString] + predicate.values)
    }

    func enqueueReconciliation(rootID: UUID, relativePath: String, recursive: Bool, reason: String) throws {
        let sql = "INSERT INTO pending_reconciliations (root_id,relative_path,recursive,reason,created_at,retry_count) VALUES (?,?,?,?,?,0) ON CONFLICT(root_id,relative_path) DO UPDATE SET recursive=MAX(recursive,excluded.recursive), reason=excluded.reason, created_at=excluded.created_at"
        try execute(sql, [rootID.uuidString, relativePath, recursive ? 1 : 0, reason, Date.now.timeIntervalSince1970])
    }

    func pendingReconciliations() throws -> [(UUID, String, Bool, String)] {
        let statement = try prepare("SELECT root_id, relative_path, recursive, reason FROM pending_reconciliations ORDER BY created_at")
        defer { sqlite3_finalize(statement) }
        var output: [(UUID, String, Bool, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rootText = string(statement, 0), let rootID = UUID(uuidString: rootText), let path = string(statement, 1), let reason = string(statement, 3) else { continue }
            output.append((rootID, path, sqlite3_column_int(statement, 2) != 0, reason))
        }
        return output
    }

    func completeReconciliation(rootID: UUID, relativePath: String) throws {
        try execute("DELETE FROM pending_reconciliations WHERE root_id = ? AND relative_path = ?", [rootID.uuidString, relativePath])
    }

    // Fallback when a separate read-only connection cannot be opened.
    func search(tokens: [String], limit: Int) throws -> [(UUID, String, String)] {
        guard !Task.isCancelled, !tokens.isEmpty else { return [] }
        // SQLite can scan many rows inside one sqlite3_step. Interrupt that
        // work promptly when a newer keystroke cancels this search task.
        sqlite3_progress_handler(db, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        let clauses = tokens.map { _ in "(normalized_name LIKE ? ESCAPE '\\' OR normalized_path LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
        let sql = "SELECT root_id, relative_path, name FROM folders WHERE \(clauses) LIMIT ?"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for token in tokens { let value = "%\(FolderSearchNormalizer.escapeLike(token))%"; bind(value, to: statement, at: index); index += 1; bind(value, to: statement, at: index); index += 1 }
        sqlite3_bind_int(statement, index, Int32(limit))
        var output: [(UUID, String, String)] = []
        while true {
            if Task.isCancelled { throw CancellationError() }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            if status == SQLITE_INTERRUPT && Task.isCancelled { throw CancellationError() }
            guard status == SQLITE_ROW else { throw DatabaseError.sqlite(message) }
            if let idText = string(statement, 0), let id = UUID(uuidString: idText), let relative = string(statement, 1), let name = string(statement, 2) { output.append((id, relative, name)) }
        }
        return output
    }

    private enum DatabaseError: LocalizedError {
        case open, sqlite(String)
        var errorDescription: String? {
            switch self {
            case .open: return "Unable to open the local folder index database."
            case .sqlite(let message): return "SQLite error: \(message)"
            }
        }
    }
    private func execute(_ sql: String, _ values: [Any?] = []) throws { let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }; try step(statement) }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw DatabaseError.sqlite(message) }; return statement }
    /// Some PRAGMAs (notably `journal_mode`) return a row. Consume all rows so
    /// callers that only need the side effect do not mistake a valid result for
    /// a failed statement.
    private func step(_ statement: OpaquePointer?) throws {
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw DatabaseError.sqlite(message) }
    }
    private func transaction(_ body: () throws -> Void) throws { try execute("BEGIN IMMEDIATE"); do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error } }
    private func scalarInt(_ sql: String, _ values: [Any?]) throws -> Int { let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }; guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }; return Int(sqlite3_column_int(statement, 0)) }
    private func subtreePredicate(_ relativePath: String) -> (sql: String, values: [Any?]) {
        guard !relativePath.isEmpty else { return ("1", []) }
        return ("(relative_path = ? OR relative_path LIKE ? ESCAPE '\\')", [relativePath, FolderSearchNormalizer.escapeLike(relativePath) + "/%"])
    }
    private var message: String { db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error" }
    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String? { guard let value = sqlite3_column_text(statement, column) else { return nil }; return String(cString: value) }
    private func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? { guard let bytes = sqlite3_column_blob(statement, column) else { return nil }; return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))) }
    private func bind(_ value: Any?, to statement: OpaquePointer?, at index: Int32) { switch value { case nil: sqlite3_bind_null(statement, index); case let value as String: sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT); case let value as Data: value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }; case let value as Double: sqlite3_bind_double(statement, index, value); case let value as Int: sqlite3_bind_int(statement, index, Int32(value)); default: sqlite3_bind_null(statement, index) } }
}

/// A second WAL connection lets searches run while the index writer is busy
/// committing scan batches. It never mutates the database.
actor FolderIndexSearchDatabase {
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SearchError.open
        }
        sqlite3_busy_timeout(db, 1_000)
    }

    deinit { if let db { sqlite3_close(db) } }

    func search(tokens: [String], limit: Int) throws -> [(UUID, String, String)] {
        guard !Task.isCancelled, !tokens.isEmpty else { return [] }
        sqlite3_progress_handler(db, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        let clauses = tokens.map { _ in "(normalized_name LIKE ? ESCAPE '\\' OR normalized_path LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
        let sql = "SELECT root_id, relative_path, name FROM folders WHERE \(clauses) LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SearchError.query }
        defer { sqlite3_finalize(statement) }
        var parameter: Int32 = 1
        for token in tokens {
            let pattern = "%\(FolderSearchNormalizer.escapeLike(token))%"
            sqlite3_bind_text(statement, parameter, pattern, -1, SQLITE_TRANSIENT); parameter += 1
            sqlite3_bind_text(statement, parameter, pattern, -1, SQLITE_TRANSIENT); parameter += 1
        }
        sqlite3_bind_int(statement, parameter, Int32(limit))
        var output: [(UUID, String, String)] = []
        while true {
            if Task.isCancelled { throw CancellationError() }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            if status == SQLITE_INTERRUPT && Task.isCancelled { throw CancellationError() }
            guard status == SQLITE_ROW else { throw SearchError.query }
            guard let idBytes = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idBytes)),
                  let relativeBytes = sqlite3_column_text(statement, 1),
                  let nameBytes = sqlite3_column_text(statement, 2) else { continue }
            output.append((id, String(cString: relativeBytes), String(cString: nameBytes)))
        }
        return output
    }

    private enum SearchError: Error { case open, query }
}
