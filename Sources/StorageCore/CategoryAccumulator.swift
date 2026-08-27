import Foundation

/// Exact byte/file counters with memory bounded by category count and contributor limit.
/// Observing a file is O(log contributorLimit), which is effectively O(1) for the fixed
/// small limit used by the scanner.
public struct CategoryAccumulator: Sendable {
    private struct State: Sendable {
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var fileCount = 0
        var contributors: TopItemHeap

        init(contributorLimit: Int) {
            contributors = TopItemHeap(limit: contributorLimit)
        }
    }

    public let contributorLimit: Int
    private var states: [ItemCategory: State] = [:]
    private var totalLogicalBytes: Int64 = 0
    private var totalAllocatedBytes: Int64 = 0

    public init(contributorLimit: Int = 8) {
        self.contributorLimit = max(1, contributorLimit)
        states.reserveCapacity(ItemCategory.allCases.count)
    }

    public mutating func observe(_ item: FileSystemItem) {
        guard !item.isDirectory else { return }
        var state = states[item.category] ?? State(contributorLimit: contributorLimit)
        state.logicalBytes = Self.saturatingAdd(state.logicalBytes, max(0, item.logicalSize))
        state.allocatedBytes = Self.saturatingAdd(state.allocatedBytes, max(0, item.allocatedSize))
        if state.fileCount < Int.max { state.fileCount += 1 }
        state.contributors.insert(item)
        states[item.category] = state
        totalLogicalBytes = Self.saturatingAdd(totalLogicalBytes, max(0, item.logicalSize))
        totalAllocatedBytes = Self.saturatingAdd(totalAllocatedBytes, max(0, item.allocatedSize))
    }

    public func makeReport(permissionErrors: Int = 0, isComplete: Bool, generatedAt: Date = Date()) -> CategoryReport {
        let summaries = ItemCategory.allCases.map { category -> CategorySummary in
            let state = states[category]
            return CategorySummary(
                category: category,
                logicalBytes: state?.logicalBytes ?? 0,
                allocatedBytes: state?.allocatedBytes ?? 0,
                fileCount: state?.fileCount ?? 0,
                topContributors: state?.contributors.descending() ?? []
            )
        }
        return CategoryReport(
            summaries: summaries,
            identifiedLogicalBytes: totalLogicalBytes,
            identifiedAllocatedBytes: totalAllocatedBytes,
            permissionErrors: permissionErrors,
            isComplete: isComplete,
            generatedAt: generatedAt
        )
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
