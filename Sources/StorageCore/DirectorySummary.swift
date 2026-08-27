import Foundation

/// A compact, persistent representation of a directory.
///
/// StorageScope keeps these records instead of retaining every file in memory. File
/// metadata is read on demand by ``DirectoryBrowserService`` while directory sizes
/// come from the most recently completed index.
public struct DirectorySummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public var path: String { url.path }
    public var parentPath: String { url.deletingLastPathComponent().path }

    public let volumeID: String
    public let url: URL
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let directFileCount: Int
    public let directDirectoryCount: Int
    public let descendantFileCount: Int
    public let descendantDirectoryCount: Int
    public let isPackage: Bool
    public let isHidden: Bool
    public let creationDate: Date?
    public let modificationDate: Date?

    public init(
        volumeID: String,
        url: URL,
        logicalSize: Int64,
        allocatedSize: Int64,
        directFileCount: Int = 0,
        directDirectoryCount: Int = 0,
        descendantFileCount: Int = 0,
        descendantDirectoryCount: Int = 0,
        isPackage: Bool = false,
        isHidden: Bool = false,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.volumeID = volumeID
        self.url = url.standardizedFileURL
        self.logicalSize = max(0, logicalSize)
        self.allocatedSize = max(0, allocatedSize)
        self.directFileCount = max(0, directFileCount)
        self.directDirectoryCount = max(0, directDirectoryCount)
        self.descendantFileCount = max(0, descendantFileCount)
        self.descendantDirectoryCount = max(0, descendantDirectoryCount)
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    public init(
        item: FileSystemItem,
        volumeID: String,
        directFileCount: Int = 0,
        directDirectoryCount: Int = 0,
        descendantFileCount: Int = 0,
        descendantDirectoryCount: Int = 0
    ) {
        self.init(
            volumeID: volumeID,
            url: item.url,
            logicalSize: item.logicalSize,
            allocatedSize: item.allocatedSize,
            directFileCount: directFileCount,
            directDirectoryCount: directDirectoryCount,
            descendantFileCount: descendantFileCount,
            descendantDirectoryCount: descendantDirectoryCount,
            isPackage: item.isPackage,
            isHidden: item.isHidden,
            creationDate: item.creationDate,
            modificationDate: item.modificationDate
        )
    }

    /// Rebuilds the public item used by the UI without requiring a retained file row.
    public var fileSystemItem: FileSystemItem {
        FileSystemItem(
            url: url,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            isDirectory: true,
            isPackage: isPackage,
            isHidden: isHidden,
            creationDate: creationDate,
            modificationDate: modificationDate,
            category: FileTypeClassifier.category(for: url, isDirectory: true, isPackage: isPackage),
            safety: FileTypeClassifier.safety(for: url, isDirectory: true)
        )
    }
}

public struct DirectoryIndexMetadata: Hashable, Codable, Sendable {
    public let volumeID: String
    public let root: URL
    public let scanID: UUID?
    public let indexVersion: Int
    public let updatedAt: Date?

    public init(volumeID: String, root: URL, scanID: UUID?, indexVersion: Int, updatedAt: Date?) {
        self.volumeID = volumeID
        self.root = root
        self.scanID = scanID
        self.indexVersion = indexVersion
        self.updatedAt = updatedAt
    }
}
