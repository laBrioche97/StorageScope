import Foundation
import SQLite3

public struct TreeIndexState: Codable, Sendable {
    public let generation: UUID
    public let checkpoint: JournalCheckpoint?
    public let snapshot: ScanSnapshot
    public let synchronizedAt: Date?
    public let pending: [TreeReplacement]
    public init(generation: UUID, checkpoint: JournalCheckpoint?, snapshot: ScanSnapshot, synchronizedAt: Date?, pending: [TreeReplacement] = []) {
        self.generation = generation; self.checkpoint = checkpoint; self.snapshot = snapshot; self.synchronizedAt = synchronizedAt; self.pending = pending
    }
}

public struct TreeReplacement: Codable, Sendable {
    public let directory: URL
    public let recursive: Bool
    public init(directory: URL, recursive: Bool) { self.directory = directory; self.recursive = recursive }
}

// Path, category and sizes already have indexed columns. Avoid encoding them a
// second time (including URL percent escaping) for every file in a large scan.
private struct TreeFileMetadata: Codable {
    let package: Bool
    let hidden: Bool
    let created: Date?
    let modified: Date?
    let identity: FileIdentity?
    let volumeUUID: String?
    let safety: SafetyLevel
    let known: Bool?
    init(_ item: FileSystemItem) {
        package = item.isPackage; hidden = item.isHidden; created = item.creationDate
        modified = item.modificationDate; identity = item.indexedIdentity; volumeUUID = item.indexedVolumeUUID; safety = item.safety; known = item.sizeIsKnown
    }
}

extension DirectoryIndexStore {
    private func prepareTreeTables() throws {
        try Self.execute("""
            CREATE TABLE IF NOT EXISTS tree_items (
                generation TEXT NOT NULL, path TEXT NOT NULL, parent_path TEXT NOT NULL,
                is_directory INTEGER NOT NULL, logical_size INTEGER NOT NULL, allocated_size INTEGER NOT NULL,
                category TEXT NOT NULL, cleanup_candidate INTEGER NOT NULL, metadata TEXT NOT NULL,
                PRIMARY KEY(generation, path)
            );
            CREATE INDEX IF NOT EXISTS tree_parent ON tree_items(generation, parent_path);
            CREATE INDEX IF NOT EXISTS tree_sizes ON tree_items(generation, is_directory, allocated_size DESC);
            CREATE INDEX IF NOT EXISTS tree_categories ON tree_items(generation, is_directory, category, allocated_size DESC);
            """, operation: "préparation de l’arborescence", database: requireDatabase())
    }

    public func beginTreeGeneration(_ generation: UUID) throws {
        try prepareTreeTables()
        // A database lease makes late writers from another task/process harmless.
        let db = try requireDatabase()
        try Self.execute("BEGIN IMMEDIATE", operation: "nouvelle génération temporaire", database: db)
        do {
            guard generation.uuidString != (try metadataValue("tree_generation")) else { throw DirectoryIndexError.unavailable }
            let statement = try Self.prepare("DELETE FROM tree_items WHERE generation <> ?", operation: "nettoyage des générations temporaires", database: db)
            defer { sqlite3_finalize(statement) }
            try Self.bindText(try metadataValue("tree_generation") ?? "", at: 1, to: statement, database: db)
            try Self.stepDone(statement, operation: "nettoyage des générations temporaires", database: db)
            try setMetadata("tree_writer", value: generation.uuidString)
            try Self.execute("COMMIT", operation: "validation de la génération temporaire", database: db)
        } catch { try? Self.execute("ROLLBACK", operation: "annulation de la génération temporaire", database: db); throw error }
    }

    private func validateWriter(_ generation: UUID) throws {
        guard try metadataValue("tree_writer") == generation.uuidString else { throw DirectoryIndexError.unavailable }
    }

    public func discardTreeGeneration(_ generation: UUID) throws {
        guard generation.uuidString != (try metadataValue("tree_generation")) else { throw DirectoryIndexError.unavailable }
        let db = try requireDatabase()
        let stmt = try Self.prepare("DELETE FROM tree_items WHERE generation = ?", operation: "abandon du lot temporaire", database: db)
        defer { sqlite3_finalize(stmt) }
        try Self.bindText(generation.uuidString, at: 1, to: stmt, database: db)
        try Self.stepDone(stmt, operation: "abandon du lot temporaire", database: db)
    }

    public func appendTreeItems(_ items: [FileSystemItem], generation: UUID) throws {
        guard !items.isEmpty else { return }
        let db = try requireDatabase()
        let statement = try Self.prepare("INSERT OR REPLACE INTO tree_items VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", operation: "écriture des fichiers", database: db)
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let generationID = generation.uuidString
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try Self.execute("BEGIN IMMEDIATE", operation: "lot de fichiers", database: db)
        do {
            try validateWriter(generation)
            for item in items {
                try Task.checkCancellation()
                try validatePath(item.url.path)
                guard !item.isSymbolicLink else { continue }
                let strings: [(Int32, String)] = [(1, generationID), (2, item.url.path), (3, item.parentPath), (7, item.category.rawValue), (9, String(decoding: try encoder.encode(TreeFileMetadata(item)), as: UTF8.self))]
                for (position, value) in strings { try Self.bindText(value, at: position, to: statement, database: db) }
                sqlite3_bind_int(statement, 4, item.isDirectory ? 1 : 0)
                sqlite3_bind_int64(statement, 5, item.logicalSize)
                sqlite3_bind_int64(statement, 6, item.allocatedSize)
                let cleanup = item.url.path.hasPrefix(home + "/Downloads/") || item.url.path.hasPrefix(home + "/Library/Logs/DiagnosticReports/") || ["package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"].contains(item.name)
                sqlite3_bind_int(statement, 8, cleanup ? 1 : 0)
                try Self.stepDone(statement, operation: "écriture des fichiers", database: db)
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
            try Self.execute("COMMIT", operation: "validation du lot", database: db)
        } catch {
            try? Self.execute("ROLLBACK", operation: "annulation du lot", database: db)
            throw error
        }
    }

    public func completeTreeGeneration(_ generation: UUID, directories: [DirectorySummary], snapshot: ScanSnapshot, checkpoint: JournalCheckpoint?) throws {
        let db = try requireDatabase()
        try Task.checkCancellation()
        try Self.execute("BEGIN IMMEDIATE", operation: "publication de l’analyse", database: db)
        do {
            try validateWriter(generation)
            try replaceAll(directories, scanID: snapshot.scanID, indexVersion: Self.schemaVersion, transactional: false)
            try setMetadata("tree_generation", value: generation.uuidString)
            try saveTreeState(TreeIndexState(generation: generation, checkpoint: checkpoint, snapshot: snapshot, synchronizedAt: nil))
            try Task.checkCancellation()
            try Self.execute("COMMIT", operation: "publication de l’analyse", database: db)
        } catch { try? Self.execute("ROLLBACK", operation: "annulation de l’analyse", database: db); throw error }
    }

    public func treeState() throws -> TreeIndexState? {
        guard let value = try metadataValue("tree_state"), let data = value.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(TreeIndexState.self, from: data)
    }

    private func saveTreeState(_ state: TreeIndexState) throws {
        try setMetadata("tree_state", value: String(decoding: JSONEncoder().encode(state), as: UTF8.self))
    }

    /// Complete children, including small files absent from all overview heaps.
    public func indexedChildren(of directory: URL, includeHidden: Bool = true) throws -> [FileSystemItem]? {
        try validatePath(directory.path)
        guard let generation = try metadataValue("tree_generation") else { return nil }
        var items = try treeItems(generation: generation, predicate: "parent_path = ? AND path <> ?", arguments: [directory.path, directory.path])
        let totals = try summaries(forPaths: items.filter(\.isDirectory).map { $0.url.path })
        items = items.compactMap { item in
            guard includeHidden || !item.isHidden else { return nil }
            var item = item
            if item.isDirectory, let total = totals[item.url.path] {
                item.logicalSize = total.logicalSize; item.allocatedSize = total.allocatedSize; item.sizeIsKnown = true
            }
            return item
        }
        return items
    }

    private func treeItems(generation: String, predicate: String, arguments: [String] = [], suffix: String = "") throws -> [FileSystemItem] {
        let db = try requireDatabase()
        let stmt = try Self.prepare("SELECT path, logical_size, allocated_size, category, is_directory, metadata FROM tree_items WHERE generation = ? AND (\(predicate)) \(suffix)", operation: "lecture des fichiers indexés", database: db)
        defer { sqlite3_finalize(stmt) }
        for (i, value) in ([generation] + arguments).enumerated() { try Self.bindText(value, at: Int32(i + 1), to: stmt, database: db) }
        let decoder = JSONDecoder()
        var result: [FileSystemItem] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw DirectoryIndexError.sqlite(operation: "lecture de l’arborescence", code: code, message: String(cString: sqlite3_errmsg(db))) }
            try Task.checkCancellation()
            let path = String(cString: sqlite3_column_text(stmt, 0))
            guard let category = ItemCategory(rawValue: String(cString: sqlite3_column_text(stmt, 3))) else { throw DirectoryIndexError.unavailable }
            let text = String(cString: sqlite3_column_text(stmt, 5))
            let metadata = try decoder.decode(TreeFileMetadata.self, from: Data(text.utf8))
            result.append(FileSystemItem(url: URL(fileURLWithPath: path), logicalSize: sqlite3_column_int64(stmt, 1), allocatedSize: sqlite3_column_int64(stmt, 2), isDirectory: sqlite3_column_int(stmt, 4) != 0, isPackage: metadata.package, isHidden: metadata.hidden, creationDate: metadata.created, modificationDate: metadata.modified, category: category, safety: metadata.safety, sizeIsKnown: metadata.known, indexedIdentity: metadata.identity, indexedVolumeUUID: metadata.volumeUUID))
        }
        return result
    }

    /// The file-system reads were staged outside this transaction. Readers see the old
    /// tree until its replacements, ancestor totals and journal cursor commit together.
    public func applyTreeChanges(staged: UUID, replacements: [TreeReplacement], checkpoint: JournalCheckpoint, issues: [ScanIssue], pending: [TreeReplacement] = []) throws -> TreeIndexState {
        guard let old = try treeState() else { throw DirectoryIndexError.unavailable }
        let generation = old.generation.uuidString
        let db = try requireDatabase()
        try Self.execute("BEGIN IMMEDIATE", operation: "actualisation de l’arborescence", database: db)
        do {
            try validateWriter(staged)
            var affected = Set<String>()
            // A removed direct child can be an entire old directory. Prune its
            // descendants too; a shallow parent refresh must not leave ghosts.
            for replacement in replacements where !replacement.recursive {
                let oldChildren = try children(of: replacement.directory.path).filter { $0.path != replacement.directory.path }
                let freshChildren = try treeItems(generation: staged.uuidString, predicate: "parent_path = ? AND is_directory = 1", arguments: [replacement.directory.path])
                let names = Set(freshChildren.map { $0.url.path })
                for removed in oldChildren where !names.contains(removed.path) {
                    try deleteTreeSubtree(removed.path, generation: generation)
                    try removeSubtree(at: removed.path)
                }
            }
            for replacement in replacements {
                let path = replacement.directory.standardized.path
                try validatePath(path)
                let predicate = replacement.recursive ? "(path = ? OR substr(path, 1, length(?)) = ?)" : "(parent_path = ? AND path <> ?)"
                let stmt = try Self.prepare("DELETE FROM tree_items WHERE generation = ? AND \(predicate)", operation: "remplacement des métadonnées", database: db)
                defer { sqlite3_finalize(stmt) }
                let args = replacement.recursive ? [generation, path, path == "/" ? "/" : path + "/", path == "/" ? "/" : path + "/"] : [generation, path, path]
                for (i, value) in args.enumerated() { try Self.bindText(value, at: Int32(i + 1), to: stmt, database: db) }
                try Self.stepDone(stmt, operation: "remplacement des métadonnées", database: db)
                if replacement.recursive { try removeSubtree(at: path) }
                var ancestor = URL(fileURLWithPath: path)
                while true {
                    affected.insert(ancestor.path)
                    if ancestor.path == root.path { break }
                    ancestor.deleteLastPathComponent()
                }
            }
            let dirs = try treeItems(generation: staged.uuidString, predicate: "is_directory = 1")
            affected.formUnion(dirs.map { $0.url.path })
            let merge = try Self.prepare("INSERT OR REPLACE INTO tree_items SELECT ?, path, parent_path, is_directory, logical_size, allocated_size, category, cleanup_candidate, metadata FROM tree_items WHERE generation = ?", operation: "fusion des changements", database: db)
            defer { sqlite3_finalize(merge) }
            try Self.bindText(generation, at: 1, to: merge, database: db); try Self.bindText(staged.uuidString, at: 2, to: merge, database: db)
            try Self.stepDone(merge, operation: "fusion des changements", database: db)
            try rebuildAffectedDirectories(affected, generation: generation)
            let unresolved = old.snapshot.issues.filter { issue in !replacements.contains { issue.path == $0.directory.path || issue.path.hasPrefix($0.directory.path == "/" ? "/" : $0.directory.path + "/") } } + issues
            let snapshot = replacements.isEmpty && issues.isEmpty ? old.snapshot : try makeTreeSnapshot(old: old.snapshot, generation: generation, issues: unresolved)
            let state = TreeIndexState(generation: old.generation, checkpoint: checkpoint, snapshot: snapshot, synchronizedAt: Date(), pending: pending)
            try saveTreeState(state)
            try Task.checkCancellation()
            try Self.execute("COMMIT", operation: "validation des changements", database: db)
            return state
        } catch { try? Self.execute("ROLLBACK", operation: "annulation des changements", database: db); throw error }
    }

    private func deleteTreeSubtree(_ path: String, generation: String) throws {
        let db = try requireDatabase()
        let stmt = try Self.prepare("DELETE FROM tree_items WHERE generation = ? AND (path = ? OR substr(path,1,length(?)) = ?)", operation: "retrait des descendants disparus", database: db)
        defer { sqlite3_finalize(stmt) }
        for (i, value) in [generation, path, path + "/", path + "/"].enumerated() { try Self.bindText(value, at: Int32(i + 1), to: stmt, database: db) }
        try Self.stepDone(stmt, operation: "retrait des descendants disparus", database: db)
    }

    private func rebuildAffectedDirectories(_ paths: Set<String>, generation: String) throws {
        let db = try requireDatabase()
        for path in paths.sorted(by: { $0.count > $1.count }) {
            try Task.checkCancellation()
            let item = try treeItems(generation: generation, predicate: "path = ? AND is_directory = 1", arguments: [path]).first
            if item == nil && path != root.path { continue }
            let base = item ?? FileSystemItem(url: root, logicalSize: 0, allocatedSize: 0, isDirectory: true)
            let count = try Self.prepare("SELECT COALESCE(SUM(logical_size),0), COALESCE(SUM(allocated_size),0), COUNT(*) FROM tree_items WHERE generation = ? AND parent_path = ? AND is_directory = 0", operation: "total des fichiers modifiés", database: db)
            defer { sqlite3_finalize(count) }
            try Self.bindText(generation, at: 1, to: count, database: db); try Self.bindText(path, at: 2, to: count, database: db)
            guard sqlite3_step(count) == SQLITE_ROW else { throw DirectoryIndexError.unavailable }
            let children = try children(of: path).filter { $0.path != path }
            let summary = DirectorySummary(item: FileSystemItem(url: base.url, logicalSize: children.reduce(sqlite3_column_int64(count, 0)) { SaturatingArithmetic.addNonnegative($0, $1.logicalSize) }, allocatedSize: children.reduce(sqlite3_column_int64(count, 1)) { SaturatingArithmetic.addNonnegative($0, $1.allocatedSize) }, isDirectory: true, isPackage: base.isPackage, isHidden: base.isHidden, creationDate: base.creationDate, modificationDate: base.modificationDate, category: base.category, safety: base.safety), volumeID: volumeID, directFileCount: Int(sqlite3_column_int64(count, 2)), directDirectoryCount: children.count)
            let insert = try Self.prepare("INSERT OR REPLACE INTO directories VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", operation: "actualisation des parents", database: db)
            defer { sqlite3_finalize(insert) }
            try Self.bind(summary, to: insert, database: db); try Self.stepDone(insert, operation: "actualisation des parents", database: db)
        }
    }

    private func makeTreeSnapshot(old: ScanSnapshot, generation: String, issues: [ScanIssue]) throws -> ScanSnapshot {
        let db = try requireDatabase()
        var categories: [CategorySummary] = []
        for category in ItemCategory.allCases {
            let stmt = try Self.prepare("SELECT COALESCE(SUM(logical_size),0), COALESCE(SUM(allocated_size),0), COUNT(*) FROM tree_items WHERE generation = ? AND category = ? AND is_directory = 0", operation: "actualisation des catégories", database: db)
            defer { sqlite3_finalize(stmt) }
            try Self.bindText(generation, at: 1, to: stmt, database: db); try Self.bindText(category.rawValue, at: 2, to: stmt, database: db)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw DirectoryIndexError.unavailable }
            categories.append(CategorySummary(category: category, logicalBytes: sqlite3_column_int64(stmt, 0), allocatedBytes: sqlite3_column_int64(stmt, 1), fileCount: Int(sqlite3_column_int64(stmt, 2)), topContributors: try treeItems(generation: generation, predicate: "is_directory = 0 AND category = ?", arguments: [category.rawValue], suffix: "ORDER BY allocated_size DESC, path LIMIT 500")))
        }
        let report = CategoryReport(summaries: categories, permissionErrors: issues.filter(\.isPermissionError).count, isComplete: true)
        let directories = try Self.prepare("SELECT \(Self.summaryColumns) FROM directories ORDER BY allocated_size DESC, path LIMIT 2000", operation: "actualisation des dossiers principaux", database: db)
        defer { sqlite3_finalize(directories) }
        var tops: [FileSystemItem] = []
        while true {
            let code = sqlite3_step(directories)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw DirectoryIndexError.unavailable }
            tops.append(Self.decodeSummary(directories, volumeID: volumeID).fileSystemItem)
        }
        var cleanup = CleanupAnalyzer()
        for item in try treeItems(generation: generation, predicate: "is_directory = 0 AND cleanup_candidate = 1") { cleanup.observeFile(item) }
        let allDirs = try treeItems(generation: generation, predicate: "is_directory = 1")
        let totals = try summaries(forPaths: allDirs.map { $0.url.path })
        let directoryItems = allDirs.compactMap { item -> FileSystemItem? in
            guard let total = totals[item.url.path] else { return nil }
            var item = item; item.logicalSize = total.logicalSize; item.allocatedSize = total.allocatedSize; item.sizeIsKnown = true
            return item
        }
        let progress = ScanProgress(filesScanned: categories.reduce(0) { $0 + $1.fileCount }, directoriesScanned: allDirs.filter { $0.url.path != root.path }.count, allocatedBytesDiscovered: report.identifiedAllocatedBytes, logicalBytesDiscovered: report.identifiedLogicalBytes, currentPath: root.path, permissionErrors: report.permissionErrors, skippedItems: old.progress.skippedItems, startedAt: old.progress.startedAt)
        return ScanSnapshot(root: root, progress: progress, topFiles: try treeItems(generation: generation, predicate: "is_directory = 0", suffix: "ORDER BY allocated_size DESC, path LIMIT 2000"), topDirectories: tops, directoryContents: [:], issues: Array(issues.prefix(500)), cleanupReport: cleanup.makeReport(directories: directoryItems, permissionErrors: report.permissionErrors, isComplete: true), completedAt: old.completedAt, scanID: old.scanID, volumeID: volumeID, indexVersion: Self.schemaVersion, categoryReport: report)
    }
}
