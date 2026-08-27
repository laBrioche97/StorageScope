import Foundation

public enum ItemCategory: String, Codable, CaseIterable, Sendable {
    case application = "Applications"
    case applicationData = "Données d’applications"
    case image = "Images"
    case video = "Vidéos"
    case audio = "Audio"
    case document = "Documents"
    case archive = "Archives"
    case development = "Développement"
    case virtualMachine = "Machines virtuelles"
    case backup = "Sauvegardes"
    case mailAndMessages = "Mail et Messages"
    case cacheAndLogs = "Caches et journaux"
    case systemAndLibrary = "Système et bibliothèques"
    case other = "Autres"
}

public enum SafetyLevel: String, Codable, Sendable {
    case safeToReview = "Sûr à examiner"
    case personal = "Fichier personnel"
    case review = "À vérifier"
    case system = "Système — ne pas supprimer"
}

public struct FileSystemItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let url: URL
    public let name: String

    /// The byte length visible to applications. Sparse files may have a very large logical size.
    public var logicalSize: Int64

    /// Physical blocks allocated by the file system. This is the primary ranking value.
    /// APFS compression, clones and snapshots mean it is still not a perfect measure of unique bytes.
    public var allocatedSize: Int64

    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let creationDate: Date?
    public let modificationDate: Date?
    public let category: ItemCategory
    public let safety: SafetyLevel

    public init(
        url: URL,
        name: String? = nil,
        logicalSize: Int64,
        allocatedSize: Int64,
        isDirectory: Bool,
        isSymbolicLink: Bool = false,
        isPackage: Bool = false,
        isHidden: Bool = false,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        category: ItemCategory = .other,
        safety: SafetyLevel = .review
    ) {
        self.id = url.path
        self.url = url
        self.name = name ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.category = category
        self.safety = safety
    }

    public var parentPath: String { url.deletingLastPathComponent().path }
    public var fileExtension: String { url.pathExtension.lowercased() }
    public var isTrashable: Bool {
        safety != .system
            && !DeletionSafetyPolicy.isProtectedForUserSelection(
                url, isDirectory: isDirectory, homeURL: DeletionSafetyPolicy.currentHomeURL
            )
    }
}

public struct ScanIssue: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let path: String
    public let message: String
    public let isPermissionError: Bool

    public init(path: String, message: String, isPermissionError: Bool) {
        self.id = UUID()
        self.path = path
        self.message = message
        self.isPermissionError = isPermissionError
    }
}

public struct ScanProgress: Hashable, Codable, Sendable {
    public var filesScanned = 0
    public var directoriesScanned = 0
    public var allocatedBytesDiscovered: Int64 = 0
    public var logicalBytesDiscovered: Int64 = 0
    public var currentPath = ""
    public var permissionErrors = 0
    public var skippedItems = 0
    public var startedAt = Date()

    public init(
        filesScanned: Int = 0,
        directoriesScanned: Int = 0,
        allocatedBytesDiscovered: Int64 = 0,
        logicalBytesDiscovered: Int64 = 0,
        currentPath: String = "",
        permissionErrors: Int = 0,
        skippedItems: Int = 0,
        startedAt: Date = Date()
    ) {
        self.filesScanned = filesScanned
        self.directoriesScanned = directoriesScanned
        self.allocatedBytesDiscovered = allocatedBytesDiscovered
        self.logicalBytesDiscovered = logicalBytesDiscovered
        self.currentPath = currentPath
        self.permissionErrors = permissionErrors
        self.skippedItems = skippedItems
        self.startedAt = startedAt
    }
}

public struct ScanSnapshot: Codable, Sendable {
    public let scanID: UUID
    public let volumeID: String
    public let indexVersion: Int
    public let root: URL
    public let progress: ScanProgress
    public let topFiles: [FileSystemItem]
    public let topDirectories: [FileSystemItem]
    public let directoryContents: [String: [FileSystemItem]]
    public let issues: [ScanIssue]
    public let cleanupReport: CleanupReport?
    public let categoryReport: CategoryReport
    public let completedAt: Date?

    public init(
        root: URL,
        progress: ScanProgress,
        topFiles: [FileSystemItem],
        topDirectories: [FileSystemItem],
        directoryContents: [String: [FileSystemItem]],
        issues: [ScanIssue],
        cleanupReport: CleanupReport? = nil,
        completedAt: Date?,
        scanID: UUID = UUID(),
        volumeID: String? = nil,
        indexVersion: Int = 1,
        categoryReport: CategoryReport? = nil
    ) {
        self.scanID = scanID
        self.volumeID = volumeID ?? root.standardizedFileURL.path
        self.indexVersion = indexVersion
        self.root = root
        self.progress = progress
        self.topFiles = topFiles
        self.topDirectories = topDirectories
        self.directoryContents = directoryContents
        self.issues = issues
        self.cleanupReport = cleanupReport
        self.categoryReport = categoryReport ?? CategoryReport.legacy(topFiles: topFiles)
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case scanID, volumeID, indexVersion, root, progress, topFiles, topDirectories, directoryContents, issues, cleanupReport, categoryReport, completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(URL.self, forKey: .root)
        scanID = try container.decodeIfPresent(UUID.self, forKey: .scanID) ?? UUID()
        volumeID = try container.decodeIfPresent(String.self, forKey: .volumeID) ?? root.standardizedFileURL.path
        indexVersion = try container.decodeIfPresent(Int.self, forKey: .indexVersion) ?? 0
        progress = try container.decode(ScanProgress.self, forKey: .progress)
        topFiles = try container.decode([FileSystemItem].self, forKey: .topFiles)
        topDirectories = try container.decode([FileSystemItem].self, forKey: .topDirectories)
        directoryContents = try container.decode([String: [FileSystemItem]].self, forKey: .directoryContents)
        issues = try container.decode([ScanIssue].self, forKey: .issues)
        cleanupReport = try container.decodeIfPresent(CleanupReport.self, forKey: .cleanupReport)
        categoryReport = try container.decodeIfPresent(CategoryReport.self, forKey: .categoryReport) ?? CategoryReport.legacy(topFiles: topFiles)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scanID, forKey: .scanID)
        try container.encode(volumeID, forKey: .volumeID)
        try container.encode(indexVersion, forKey: .indexVersion)
        try container.encode(root, forKey: .root)
        try container.encode(progress, forKey: .progress)
        try container.encode(topFiles, forKey: .topFiles)
        try container.encode(topDirectories, forKey: .topDirectories)
        try container.encode(directoryContents, forKey: .directoryContents)
        try container.encode(issues, forKey: .issues)
        try container.encodeIfPresent(cleanupReport, forKey: .cleanupReport)
        try container.encode(categoryReport, forKey: .categoryReport)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

public enum ScanEvent: Sendable {
    /// Lightweight, frequent heartbeat. It intentionally carries no rebuilt tree.
    case progress(ScanProgress)
    /// A bounded overview suitable for animated category/root UI during a scan.
    case live(ScanLiveSummary)
    case finalizing(ScanProgress)
    case update(ScanSnapshot)
    case completed(ScanSnapshot)
    case cancelled(ScanSnapshot)
}
