import Foundation
import SQLite3

public enum DirectoryIndexError: Error, LocalizedError, Sendable {
    case cannotOpen(path: String, message: String)
    case sqlite(operation: String, code: Int32, message: String)
    case volumeMismatch(expected: String, actual: String)
    case outsideRoot(path: String, root: String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, message):
            return "Impossible d’ouvrir l’index \(path) : \(message)"
        case let .sqlite(operation, code, message):
            return "Erreur SQLite pendant \(operation) (\(code)) : \(message)"
        case let .volumeMismatch(expected, actual):
            return "L’index appartient au volume \(actual), pas au volume \(expected)."
        case let .outsideRoot(path, root):
            return "Le dossier \(path) se trouve hors de la racine indexée \(root)."
        case .unavailable:
            return "L’index des dossiers n’est pas disponible."
        }
    }
}

/// SQLite-backed directory cache. One instance and database are bound to one volume.
///
/// The actor owns the SQLite connection, so callers can safely query it from scan and
/// UI tasks without adding their own locks. Replacements are atomic: readers see the
/// previous complete scan until the new transaction commits.
public actor DirectoryIndexStore {
    public static let schemaVersion = 1

    public nonisolated let volumeID: String
    public nonisolated let root: URL
    public nonisolated let databaseURL: URL

    private let connection: DirectorySQLiteConnection

    public init(volumeID: String, root: URL, databaseURL: URL? = nil) throws {
        let normalizedRoot = root.standardizedFileURL
        let resolvedDatabaseURL = try databaseURL ?? Self.defaultDatabaseURL(for: volumeID)

        self.volumeID = volumeID
        self.root = normalizedRoot
        self.databaseURL = resolvedDatabaseURL

        try FileManager.default.createDirectory(
            at: resolvedDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            resolvedDatabaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Erreur inconnue"
            if let handle { sqlite3_close(handle) }
            throw DirectoryIndexError.cannotOpen(path: resolvedDatabaseURL.path, message: message)
        }

        do {
            try Self.configure(handle)
            try Self.prepareSchema(handle)

            if let indexedVolume = try Self.metadataValue("volume_id", database: handle),
               indexedVolume != volumeID {
                throw DirectoryIndexError.volumeMismatch(expected: volumeID, actual: indexedVolume)
            }
            if let indexedRoot = try Self.metadataValue("root_path", database: handle),
               indexedRoot != normalizedRoot.path {
                throw DirectoryIndexError.outsideRoot(path: normalizedRoot.path, root: indexedRoot)
            }

            try Self.setMetadata("volume_id", value: volumeID, database: handle)
            try Self.setMetadata("root_path", value: normalizedRoot.path, database: handle)
            if try Self.metadataValue("index_version", database: handle) == nil {
                try Self.setMetadata("index_version", value: "0", database: handle)
            }
            connection = DirectorySQLiteConnection(handle: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    /// A deterministic per-volume location below Application Support.
    public static func defaultDatabaseURL(for volumeID: String) throws -> URL {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DirectoryIndexError.unavailable
        }
        let directory = applicationSupport
            .appendingPathComponent("StorageScope", isDirectory: true)
            .appendingPathComponent("DirectoryIndexes", isDirectory: true)
        let hash = stableHash(volumeID)
        return directory.appendingPathComponent("directories-v\(schemaVersion)-\(hash).sqlite", isDirectory: false)
    }

    public func metadata() throws -> DirectoryIndexMetadata {
        let scanID = try metadataValue("scan_id").flatMap(UUID.init(uuidString:))
        let indexVersion = try metadataValue("index_version").flatMap(Int.init) ?? 0
        let updatedAt = try metadataValue("updated_at")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return DirectoryIndexMetadata(
            volumeID: volumeID,
            root: root,
            scanID: scanID,
            indexVersion: indexVersion,
            updatedAt: updatedAt
        )
    }

    /// Atomically replaces the completed directory index using one prepared statement.
    /// `batchSize` bounds transient Swift work while the SQLite transaction remains atomic.
    public func replaceAll(
        _ summaries: [DirectorySummary],
        scanID: UUID? = nil,
        indexVersion: Int = 1,
        batchSize: Int = 2_000
    ) throws {
        for summary in summaries { try validate(summary) }

        let database = try requireDatabase()
        try Self.execute("BEGIN IMMEDIATE TRANSACTION", operation: "démarrage du remplacement", database: database)
        do {
            try Self.execute("DELETE FROM directories", operation: "nettoyage de l’ancien index", database: database)
            let sql = """
                INSERT INTO directories (
                    path, parent_path, logical_size, allocated_size,
                    direct_file_count, direct_directory_count,
                    descendant_file_count, descendant_directory_count,
                    is_package, is_hidden, creation_date, modification_date
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            let statement = try Self.prepare(sql, operation: "préparation de l’écriture", database: database)
            defer { sqlite3_finalize(statement) }

            let boundedBatchSize = max(1, batchSize)
            var start = 0
            while start < summaries.count {
                let end = min(start + boundedBatchSize, summaries.count)
                for summary in summaries[start..<end] {
                    try Self.bind(summary, to: statement, database: database)
                    try Self.stepDone(statement, operation: "écriture de \(summary.path)", database: database)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
                start = end
            }

            try setMetadata("scan_id", value: scanID?.uuidString)
            try setMetadata("index_version", value: String(max(0, indexVersion)))
            try setMetadata("updated_at", value: String(Date().timeIntervalSince1970))
            try Self.execute("COMMIT", operation: "validation du nouvel index", database: database)
        } catch {
            try? Self.execute("ROLLBACK", operation: "annulation du remplacement", database: database)
            throw error
        }
    }

    public func summary(forPath path: String) throws -> DirectorySummary? {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        try validatePath(normalizedPath)
        let database = try requireDatabase()
        let statement = try Self.prepare(
            "SELECT \(Self.summaryColumns) FROM directories WHERE path = ? LIMIT 1",
            operation: "lecture du dossier",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try Self.bindText(normalizedPath, at: 1, to: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return Self.decodeSummary(statement, volumeID: volumeID)
        case SQLITE_DONE:
            return nil
        default:
            throw Self.sqliteError(operation: "lecture du dossier", database: database)
        }
    }

    /// Fetches directory totals in bounded `IN` queries to stay below SQLite's variable limit.
    public func summaries(forPaths paths: [String]) throws -> [String: DirectorySummary] {
        let normalized = Array(Set(paths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }))
        for path in normalized { try validatePath(path) }
        guard !normalized.isEmpty else { return [:] }

        let database = try requireDatabase()
        var result: [String: DirectorySummary] = [:]
        result.reserveCapacity(normalized.count)
        let chunkSize = 500

        for start in stride(from: 0, to: normalized.count, by: chunkSize) {
            let end = min(start + chunkSize, normalized.count)
            let chunk = normalized[start..<end]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            do {
                let statement = try Self.prepare(
                    "SELECT \(Self.summaryColumns) FROM directories WHERE path IN (\(placeholders))",
                    operation: "lecture groupée des dossiers",
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                for (offset, path) in chunk.enumerated() {
                    try Self.bindText(path, at: Int32(offset + 1), to: statement, database: database)
                }
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else {
                        throw Self.sqliteError(operation: "lecture groupée des dossiers", database: database)
                    }
                    let summary = Self.decodeSummary(statement, volumeID: volumeID)
                    result[summary.path] = summary
                }
            }
        }
        return result
    }

    public func children(of parentPath: String) throws -> [DirectorySummary] {
        let normalizedParent = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL.path
        try validatePath(normalizedParent)
        let database = try requireDatabase()
        let statement = try Self.prepare(
            """
            SELECT \(Self.summaryColumns) FROM directories
            WHERE parent_path = ? AND path <> ?
            ORDER BY allocated_size DESC, path COLLATE NOCASE ASC
            """,
            operation: "lecture des sous-dossiers",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try Self.bindText(normalizedParent, at: 1, to: statement, database: database)
        try Self.bindText(normalizedParent, at: 2, to: statement, database: database)

        var result: [DirectorySummary] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw Self.sqliteError(operation: "lecture des sous-dossiers", database: database)
            }
            result.append(Self.decodeSummary(statement, volumeID: volumeID))
        }
        return result
    }

    @discardableResult
    public func removeSubtree(at path: String) throws -> Int {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        try validatePath(normalizedPath)
        let database = try requireDatabase()
        let statement: OpaquePointer
        if normalizedPath == root.path {
            statement = try Self.prepare("DELETE FROM directories", operation: "suppression de l’index", database: database)
        } else {
            statement = try Self.prepare(
                "DELETE FROM directories WHERE path = ? OR substr(path, 1, length(?)) = ?",
                operation: "suppression du sous-arbre",
                database: database
            )
            let prefix = normalizedPath + "/"
            try Self.bindText(normalizedPath, at: 1, to: statement, database: database)
            try Self.bindText(prefix, at: 2, to: statement, database: database)
            try Self.bindText(prefix, at: 3, to: statement, database: database)
        }
        defer { sqlite3_finalize(statement) }
        try Self.stepDone(statement, operation: "suppression du sous-arbre", database: database)
        let removed = Int(sqlite3_changes(database))
        try setMetadata("updated_at", value: String(Date().timeIntervalSince1970))
        return removed
    }

    public func clear() throws {
        let database = try requireDatabase()
        try Self.execute("BEGIN IMMEDIATE TRANSACTION", operation: "démarrage du nettoyage", database: database)
        do {
            try Self.execute("DELETE FROM directories", operation: "nettoyage de l’index", database: database)
            try setMetadata("scan_id", value: nil)
            try setMetadata("index_version", value: "0")
            try setMetadata("updated_at", value: nil)
            try Self.execute("COMMIT", operation: "validation du nettoyage", database: database)
        } catch {
            try? Self.execute("ROLLBACK", operation: "annulation du nettoyage", database: database)
            throw error
        }
    }

    private func validate(_ summary: DirectorySummary) throws {
        guard summary.volumeID == volumeID else {
            throw DirectoryIndexError.volumeMismatch(expected: volumeID, actual: summary.volumeID)
        }
        try validatePath(summary.path)
    }

    private func validatePath(_ path: String) throws {
        let rootPath = root.path
        guard rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw DirectoryIndexError.outsideRoot(path: path, root: rootPath)
        }
    }

    private func requireDatabase() throws -> OpaquePointer {
        connection.handle
    }

    private func metadataValue(_ key: String) throws -> String? {
        try Self.metadataValue(key, database: requireDatabase())
    }

    private func setMetadata(_ key: String, value: String?) throws {
        try Self.setMetadata(key, value: value, database: requireDatabase())
    }

    private static let summaryColumns = """
        path, logical_size, allocated_size,
        direct_file_count, direct_directory_count,
        descendant_file_count, descendant_directory_count,
        is_package, is_hidden, creation_date, modification_date
        """

    private static func configure(_ database: OpaquePointer) throws {
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode=WAL", operation: "activation du journal WAL", database: database)
        try execute("PRAGMA synchronous=NORMAL", operation: "configuration de la synchronisation", database: database)
        try execute("PRAGMA temp_store=MEMORY", operation: "configuration des données temporaires", database: database)
    }

    private static func prepareSchema(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(operation: "lecture de la version du schéma", database: database)
        }
        let currentVersion = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        sqlite3_finalize(statement)

        if currentVersion != schemaVersion {
            try execute("BEGIN IMMEDIATE TRANSACTION", operation: "migration du schéma", database: database)
            do {
                try execute("DROP TABLE IF EXISTS directories", operation: "réinitialisation des dossiers", database: database)
                try execute("DROP TABLE IF EXISTS metadata", operation: "réinitialisation des métadonnées", database: database)
                try createTables(database)
                try execute("PRAGMA user_version=\(schemaVersion)", operation: "versionnage du schéma", database: database)
                try execute("COMMIT", operation: "validation du schéma", database: database)
            } catch {
                try? execute("ROLLBACK", operation: "annulation de la migration", database: database)
                throw error
            }
        } else {
            try createTables(database)
        }
    }

    private static func createTables(_ database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS directories (
                path TEXT PRIMARY KEY NOT NULL,
                parent_path TEXT NOT NULL,
                logical_size INTEGER NOT NULL,
                allocated_size INTEGER NOT NULL,
                direct_file_count INTEGER NOT NULL,
                direct_directory_count INTEGER NOT NULL,
                descendant_file_count INTEGER NOT NULL,
                descendant_directory_count INTEGER NOT NULL,
                is_package INTEGER NOT NULL,
                is_hidden INTEGER NOT NULL,
                creation_date REAL,
                modification_date REAL
            );
            CREATE INDEX IF NOT EXISTS directories_parent_idx
            ON directories(parent_path, allocated_size DESC);
            """,
            operation: "création du schéma",
            database: database
        )
    }

    private static func bind(_ summary: DirectorySummary, to statement: OpaquePointer, database: OpaquePointer) throws {
        try bindText(summary.path, at: 1, to: statement, database: database)
        try bindText(summary.parentPath, at: 2, to: statement, database: database)
        sqlite3_bind_int64(statement, 3, summary.logicalSize)
        sqlite3_bind_int64(statement, 4, summary.allocatedSize)
        sqlite3_bind_int64(statement, 5, Int64(summary.directFileCount))
        sqlite3_bind_int64(statement, 6, Int64(summary.directDirectoryCount))
        sqlite3_bind_int64(statement, 7, Int64(summary.descendantFileCount))
        sqlite3_bind_int64(statement, 8, Int64(summary.descendantDirectoryCount))
        sqlite3_bind_int(statement, 9, summary.isPackage ? 1 : 0)
        sqlite3_bind_int(statement, 10, summary.isHidden ? 1 : 0)
        bindDate(summary.creationDate, at: 11, to: statement)
        bindDate(summary.modificationDate, at: 12, to: statement)
    }

    private static func decodeSummary(_ statement: OpaquePointer, volumeID: String) -> DirectorySummary {
        let path = String(cString: sqlite3_column_text(statement, 0))
        return DirectorySummary(
            volumeID: volumeID,
            url: URL(fileURLWithPath: path, isDirectory: true),
            logicalSize: sqlite3_column_int64(statement, 1),
            allocatedSize: sqlite3_column_int64(statement, 2),
            directFileCount: clampedInt(sqlite3_column_int64(statement, 3)),
            directDirectoryCount: clampedInt(sqlite3_column_int64(statement, 4)),
            descendantFileCount: clampedInt(sqlite3_column_int64(statement, 5)),
            descendantDirectoryCount: clampedInt(sqlite3_column_int64(statement, 6)),
            isPackage: sqlite3_column_int(statement, 7) != 0,
            isHidden: sqlite3_column_int(statement, 8) != 0,
            creationDate: decodeDate(statement, column: 9),
            modificationDate: decodeDate(statement, column: 10)
        )
    }

    private static func clampedInt(_ value: Int64) -> Int {
        if value > Int64(Int.max) { return Int.max }
        if value < Int64(Int.min) { return Int.min }
        return Int(value)
    }

    private static func bindDate(_ date: Date?, at index: Int32, to statement: OpaquePointer) {
        if let date {
            sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func decodeDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func metadataValue(_ key: String, database: OpaquePointer) throws -> String? {
        let statement = try prepare(
            "SELECT value FROM metadata WHERE key = ? LIMIT 1",
            operation: "lecture des métadonnées",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, to: statement, database: database)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return String(cString: sqlite3_column_text(statement, 0))
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError(operation: "lecture des métadonnées", database: database)
        }
    }

    private static func setMetadata(_ key: String, value: String?, database: OpaquePointer) throws {
        if let value {
            let statement = try prepare(
                "INSERT INTO metadata(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                operation: "écriture des métadonnées",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bindText(key, at: 1, to: statement, database: database)
            try bindText(value, at: 2, to: statement, database: database)
            try stepDone(statement, operation: "écriture des métadonnées", database: database)
        } else {
            let statement = try prepare(
                "DELETE FROM metadata WHERE key = ?",
                operation: "suppression des métadonnées",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bindText(key, at: 1, to: statement, database: database)
            try stepDone(statement, operation: "suppression des métadonnées", database: database)
        }
    }

    private static func prepare(_ sql: String, operation: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(operation: operation, database: database)
        }
        return statement
    }

    private static func bindText(_ value: String, at index: Int32, to statement: OpaquePointer, database: OpaquePointer) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else {
            throw sqliteError(operation: "liaison d’une valeur", database: database)
        }
    }

    private static func stepDone(_ statement: OpaquePointer, operation: String, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(operation: operation, database: database)
        }
    }

    private static func execute(_ sql: String, operation: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw DirectoryIndexError.sqlite(operation: operation, code: result, message: message)
        }
    }

    private static func sqliteError(operation: String, database: OpaquePointer) -> DirectoryIndexError {
        DirectoryIndexError.sqlite(
            operation: operation,
            code: sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

/// The actor is the sole caller of this connection. The wrapper only makes teardown
/// safe under Swift 6's nonisolated-deinit rules for raw C pointers.
private final class DirectorySQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}
