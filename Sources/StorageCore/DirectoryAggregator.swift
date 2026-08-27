import Foundation

/// Aggregates directories in two phases.
///
/// The hot scan path only adds each file to its immediate parent (O(files)).
/// Recursive folder totals are resolved bottom-up when a UI snapshot is requested
/// (O(directories)), instead of walking every ancestor for every file.
public struct DirectoryAggregator: Sendable {
    private struct Totals: Sendable {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var metadata: FileSystemItem?
        var newestDescendantModification: Date?
    }

    private let rootPath: String
    private let maxChildrenPerDirectory: Int
    private let maxRetainedFileChildren: Int
    private var directTotals: [String: Totals] = [:]
    private var fileChildren: [String: TopItemHeap] = [:]
    private var retainedFileChildren = 0

    public init(root: URL, maxChildrenPerDirectory: Int = 250, maxRetainedFileChildren: Int = 100_000) {
        self.rootPath = root.path
        self.maxChildrenPerDirectory = max(1, maxChildrenPerDirectory)
        self.maxRetainedFileChildren = max(0, maxRetainedFileChildren)
        self.directTotals[root.path] = Totals()
    }

    public mutating func registerDirectory(_ item: FileSystemItem) {
        let path = item.url.path
        var value = directTotals[path] ?? Totals()
        value.metadata = item
        value.newestDescendantModification = newest(value.newestDescendantModification, item.modificationDate)
        directTotals[path] = value
    }

    public mutating func addFile(_ item: FileSystemItem) {
        let parent = item.parentPath
        var value = directTotals[parent] ?? Totals()
        value.logical = SaturatingArithmetic.addNonnegative(value.logical, item.logicalSize)
        value.allocated = SaturatingArithmetic.addNonnegative(value.allocated, item.allocatedSize)
        value.newestDescendantModification = newest(value.newestDescendantModification, item.modificationDate)
        directTotals[parent] = value

        guard maxRetainedFileChildren > 0 else { return }
        if let oldCount = fileChildren[parent]?.items.count {
            guard retainedFileChildren < maxRetainedFileChildren || oldCount >= maxChildrenPerDirectory else { return }
            fileChildren[parent, default: TopItemHeap(limit: maxChildrenPerDirectory)].insert(item)
            retainedFileChildren = SaturatingArithmetic.addNonnegative(
                retainedFileChildren,
                (fileChildren[parent]?.items.count ?? oldCount) - oldCount
            )
        } else if retainedFileChildren < maxRetainedFileChildren {
            var heap = TopItemHeap(limit: maxChildrenPerDirectory)
            heap.insert(item)
            retainedFileChildren = SaturatingArithmetic.addNonnegative(retainedFileChildren, 1)
            fileChildren[parent] = heap
        }
    }

    public func directoryItems() -> [FileSystemItem] {
        resolvedTotals().map { path, value in makeDirectory(path: path, totals: value) }
    }

    /// Resolves and consumes the accumulated directory totals.
    ///
    /// The nonmutating snapshot APIs intentionally preserve the aggregator and must
    /// therefore copy its dictionary before the bottom-up fold. A completed scanner
    /// no longer needs that state, so this variant folds the uniquely-owned dictionary
    /// in place and transfers it into the returned items without keeping the original
    /// dictionary alive during finalization.
    public mutating func takeDirectoryItems() -> [FileSystemItem] {
        resolveTotalsInPlace()
        let resolved = directTotals
        directTotals = [rootPath: Totals()]
        fileChildren = [:]
        retainedFileChildren = 0
        return resolved.map { path, value in makeDirectory(path: path, totals: value) }
    }

    public func topDirectoryItems(limit: Int) -> [FileSystemItem] {
        var heap = TopItemHeap(limit: max(1, limit))
        for (path, value) in resolvedTotals() {
            heap.insert(makeDirectory(path: path, totals: value))
        }
        return heap.descending()
    }

    public func contents(with directories: [FileSystemItem]) -> [String: [FileSystemItem]] {
        var heaps = fileChildren
        for directory in directories where directory.url.path != rootPath {
            let parent = directory.parentPath
            heaps[parent, default: TopItemHeap(limit: maxChildrenPerDirectory)].insert(directory)
        }
        return heaps.mapValues { $0.descending() }
    }

    private func resolvedTotals() -> [String: Totals] {
        var copy = self
        copy.resolveTotalsInPlace()
        return copy.directTotals
    }

    private mutating func resolveTotalsInPlace() {
        // Fill potentially missing ancestors (for example when a directory vanished or
        // became inaccessible between enumeration steps) before the bottom-up fold.
        do {
            let knownPaths = Array(directTotals.keys)
            for path in knownPaths where path != rootPath {
                var parent = (path as NSString).deletingLastPathComponent
                while isInsideRoot(parent) {
                    if directTotals[parent] == nil { directTotals[parent] = Totals() }
                    if parent == rootPath { break }
                    let next = (parent as NSString).deletingLastPathComponent
                    if next == parent { break }
                    parent = next
                }
            }
        }
        // A child path is always longer than its parent path, so length ordering is
        // enough for an exact bottom-up fold and cheaper than pathComponents parsing.
        let paths = directTotals.keys.sorted { $0.count > $1.count }
        for path in paths where path != rootPath {
            let parent = (path as NSString).deletingLastPathComponent
            guard isInsideRoot(parent), let child = directTotals[path] else { continue }
            var parentValue = directTotals[parent] ?? Totals()
            parentValue.logical = SaturatingArithmetic.addNonnegative(parentValue.logical, child.logical)
            parentValue.allocated = SaturatingArithmetic.addNonnegative(parentValue.allocated, child.allocated)
            parentValue.newestDescendantModification = newest(parentValue.newestDescendantModification, child.newestDescendantModification)
            directTotals[parent] = parentValue
        }
    }

    private func makeDirectory(path: String, totals: Totals) -> FileSystemItem {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let base = totals.metadata
        let isPackage = base?.isPackage ?? false
        return FileSystemItem(
            url: url,
            logicalSize: totals.logical,
            allocatedSize: totals.allocated,
            isDirectory: true,
            isPackage: isPackage,
            isHidden: base?.isHidden ?? false,
            creationDate: base?.creationDate,
            modificationDate: totals.newestDescendantModification ?? base?.modificationDate,
            category: FileTypeClassifier.category(for: url, isDirectory: true, isPackage: isPackage),
            safety: FileTypeClassifier.safety(for: url, isDirectory: true)
        )
    }

    private func isInsideRoot(_ path: String) -> Bool {
        rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func newest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}
