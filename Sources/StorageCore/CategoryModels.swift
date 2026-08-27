import Foundation

public struct CategorySummary: Identifiable, Hashable, Codable, Sendable {
    public var id: ItemCategory { category }
    public let category: ItemCategory
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let topContributors: [FileSystemItem]

    public init(
        category: ItemCategory,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        fileCount: Int,
        topContributors: [FileSystemItem] = []
    ) {
        self.category = category
        self.logicalBytes = max(0, logicalBytes)
        self.allocatedBytes = max(0, allocatedBytes)
        self.fileCount = max(0, fileCount)
        self.topContributors = topContributors
    }
}

public struct CategoryReport: Hashable, Codable, Sendable {
    public let summaries: [CategorySummary]
    public let identifiedLogicalBytes: Int64
    public let identifiedAllocatedBytes: Int64
    public let permissionErrors: Int
    public let isComplete: Bool
    public let generatedAt: Date

    public init(
        summaries: [CategorySummary],
        identifiedLogicalBytes: Int64? = nil,
        identifiedAllocatedBytes: Int64? = nil,
        permissionErrors: Int = 0,
        isComplete: Bool,
        generatedAt: Date = Date()
    ) {
        self.summaries = summaries
        self.identifiedLogicalBytes = max(0, identifiedLogicalBytes ?? summaries.reduce(0) { $0 + $1.logicalBytes })
        self.identifiedAllocatedBytes = max(0, identifiedAllocatedBytes ?? summaries.reduce(0) { $0 + $1.allocatedBytes })
        self.permissionErrors = max(0, permissionErrors)
        self.isComplete = isComplete
        self.generatedAt = generatedAt
    }

    public static let empty = CategoryReport(summaries: [], isComplete: false, generatedAt: .distantPast)

    public func summary(for category: ItemCategory) -> CategorySummary {
        summaries.first(where: { $0.category == category }) ?? CategorySummary(
            category: category,
            logicalBytes: 0,
            allocatedBytes: 0,
            fileCount: 0
        )
    }

    /// Old JSON caches only retained a bounded top-file list. Preserve that useful
    /// information without ever presenting it as an exact, completed report.
    static func legacy(topFiles: [FileSystemItem]) -> CategoryReport {
        var accumulator = CategoryAccumulator()
        for item in topFiles where !item.isDirectory { accumulator.observe(item) }
        return accumulator.makeReport(isComplete: false)
    }
}

public struct ScanLiveSummary: Hashable, Codable, Sendable {
    public let scanID: UUID
    public let volumeID: String
    public let progress: ScanProgress
    public let categoryReport: CategoryReport
    public let rootItems: [FileSystemItem]
    public let isComplete: Bool

    public init(
        scanID: UUID,
        volumeID: String,
        progress: ScanProgress,
        categoryReport: CategoryReport,
        rootItems: [FileSystemItem] = [],
        isComplete: Bool = false
    ) {
        self.scanID = scanID
        self.volumeID = volumeID
        self.progress = progress
        self.categoryReport = categoryReport
        self.rootItems = rootItems
        self.isComplete = isComplete
    }
}
