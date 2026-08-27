import Foundation

public enum CleanupAnalysisPhase: String, Codable, Sendable {
    case preparing = "Préparation"
    case evaluatingRules = "Évaluation des règles"
    case validatingCandidates = "Validation des éléments"
    case finalizing = "Finalisation"
}

public struct CleanupAnalysisProgress: Sendable {
    public let phase: CleanupAnalysisPhase
    public let completedUnits: Int
    public let totalUnits: Int
    public let currentPath: String?

    public init(phase: CleanupAnalysisPhase, completedUnits: Int, totalUnits: Int, currentPath: String? = nil) {
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.currentPath = currentPath
    }

    public var fraction: Double {
        totalUnits > 0 ? min(1, Double(completedUnits) / Double(totalUnits)) : 0
    }
}

public enum CleanupAnalysisEvent: Sendable {
    case progress(CleanupAnalysisProgress)
    case completed(CleanupReport)
    case cancelled
}

/// Revalidates the bounded candidates collected by the single-pass scanner.
/// It performs real filesystem work without starting a second full-volume traversal.
public struct CleanupAnalysisService: Sendable {
    public init() {}

    public func analyze(_ source: CleanupReport) -> AsyncStream<CleanupAnalysisEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let visibleCount = source.suggestions.reduce(0) { $0 + $1.items.count }
                let total = max(1, visibleCount + source.suggestions.count + 2)
                var completed = 0
                continuation.yield(.progress(.init(phase: .preparing, completedUnits: completed, totalUnits: total)))

                var validated: [CleanupSuggestion] = []
                for suggestion in source.suggestions {
                    if Task.isCancelled {
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    }
                    completed += 1
                    continuation.yield(.progress(.init(phase: .evaluatingRules, completedUnits: completed, totalUnits: total)))
                    var items: [FileSystemItem] = []
                    for var item in suggestion.items {
                        if Task.isCancelled {
                            continuation.yield(.cancelled)
                            continuation.finish()
                            return
                        }
                        let path = item.url.standardizedFileURL.path
                        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .fileSizeKey, .fileAllocatedSizeKey]
                        if let values = try? item.url.resourceValues(forKeys: keys), values.isSymbolicLink != true {
                            if !item.isDirectory {
                                item.logicalSize = Int64(values.fileSize ?? Int(item.logicalSize))
                                item.allocatedSize = Int64(values.fileAllocatedSize ?? Int(item.allocatedSize))
                            }
                            items.append(item)
                        }
                        completed += 1
                        continuation.yield(.progress(.init(
                            phase: .validatingCandidates,
                            completedUnits: completed,
                            totalUnits: total,
                            currentPath: path
                        )))
                    }
                    guard !items.isEmpty || suggestion.itemCount > suggestion.items.count else { continue }
                    let bytes: Int64
                    if suggestion.itemCount == suggestion.items.count {
                        bytes = items.reduce(0) { $0 + $1.allocatedSize }
                    } else {
                        bytes = suggestion.potentialBytes
                    }
                    validated.append(CleanupSuggestion(
                        id: suggestion.id,
                        title: suggestion.title,
                        explanation: suggestion.explanation,
                        potentialBytes: bytes,
                        itemCount: suggestion.itemCount - (suggestion.items.count - items.count),
                        items: items,
                        confidence: suggestion.confidence,
                        action: suggestion.action
                    ))
                }

                continuation.yield(.progress(.init(phase: .finalizing, completedUnits: total - 1, totalUnits: total)))
                let result = CleanupReport(
                    suggestions: validated.sorted { $0.potentialBytes > $1.potentialBytes },
                    uniquePotentialBytes: validated.reduce(0) { $0 + $1.potentialBytes },
                    isComplete: source.isComplete,
                    permissionErrors: source.permissionErrors,
                    generatedAt: Date()
                )
                continuation.yield(.progress(.init(phase: .finalizing, completedUnits: total, totalUnits: total)))
                continuation.yield(.completed(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
