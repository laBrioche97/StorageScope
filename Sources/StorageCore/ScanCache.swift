import Foundation

public actor ScanCache {
    private let baseURL: URL
    private let fixedFileURL: URL?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fixedFileURL = fileURL
            self.baseURL = fileURL.deletingLastPathComponent()
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            self.baseURL = base.appendingPathComponent("StorageScope/Scans", isDirectory: true)
            self.fixedFileURL = nil
        }
    }

    /// Injectable directory used by tests and by hosts that manage their own cache root.
    /// Files remain separated by the encoded volume identifier exactly like the default cache.
    public init(baseURL: URL) {
        self.baseURL = baseURL
        self.fixedFileURL = nil
    }

    public func save(_ snapshot: ScanSnapshot) throws {
        let fileURL = fileURL(for: snapshot.volumeID)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the last scan useful but bounded: it is a stale overview, not a permanent database.
        let cachedPaths = Set(snapshot.topDirectories.prefix(500).map { $0.url.standardizedFileURL.path } + [snapshot.root.standardizedFileURL.path])
        let compact = ScanSnapshot(
            root: snapshot.root,
            progress: snapshot.progress,
            topFiles: Array(snapshot.topFiles.prefix(2_000)),
            topDirectories: Array(snapshot.topDirectories.prefix(2_000)),
            directoryContents: snapshot.directoryContents.filter { cachedPaths.contains($0.key) }.mapValues { Array($0.prefix(100)) },
            issues: Array(snapshot.issues.prefix(100)),
            cleanupReport: snapshot.cleanupReport,
            completedAt: snapshot.completedAt,
            scanID: snapshot.scanID,
            volumeID: snapshot.volumeID,
            indexVersion: snapshot.indexVersion,
            categoryReport: snapshot.categoryReport
        )
        let data = try JSONEncoder().encode(compact)
        try data.write(to: fileURL, options: .atomic)
    }

    public func load() throws -> ScanSnapshot? {
        if let fixedFileURL { return try decode(at: fixedFileURL) }
        let legacy = baseURL.deletingLastPathComponent().appendingPathComponent("last-scan.json")
        return try decode(at: legacy)
    }

    public func load(volumeID: String) throws -> ScanSnapshot? {
        if let fixedFileURL { return try decode(at: fixedFileURL) }
        if let snapshot = try decode(at: fileURL(for: volumeID)), snapshot.volumeID == volumeID {
            return snapshot
        }
        let legacy = baseURL.deletingLastPathComponent().appendingPathComponent("last-scan.json")
        guard let snapshot = try decode(at: legacy), snapshot.volumeID == volumeID || snapshot.root.standardizedFileURL.path == volumeID else { return nil }
        return snapshot
    }

    private func decode(at fileURL: URL) throws -> ScanSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(ScanSnapshot.self, from: Data(contentsOf: fileURL))
    }

    private func fileURL(for volumeID: String) -> URL {
        if let fixedFileURL { return fixedFileURL }
        let encoded = Data(volumeID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return baseURL.appendingPathComponent(encoded + ".json")
    }
}
