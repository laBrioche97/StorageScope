import Foundation
import Darwin

public final class StorageScanner: @unchecked Sendable {
    public static let currentIndexVersion = 1
    public let topFileLimit: Int
    public let topDirectoryLimit: Int
    /// Minimum delay between bounded partial result snapshots.
    public let updateInterval: Duration
    /// Delay between lightweight progress heartbeats.
    public let progressInterval: Duration

    public init(
        topFileLimit: Int = 2_000,
        topDirectoryLimit: Int = 2_000,
        updateInterval: Duration = .seconds(5),
        progressInterval: Duration = .milliseconds(150)
    ) {
        self.topFileLimit = topFileLimit
        self.topDirectoryLimit = topDirectoryLimit
        self.updateInterval = updateInterval
        self.progressInterval = progressInterval
    }

    public func scan(root: URL, volumeID requestedVolumeID: String? = nil) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(5)) { continuation in
            let task = Task.detached(priority: .userInitiated) { [topFileLimit, topDirectoryLimit, progressInterval] in
                let standardizedRoot = Self.canonicalURL(for: root)
                let rootDeviceID = Self.deviceID(for: standardizedRoot)
                let scanID = UUID()
                let volumeID = requestedVolumeID ?? standardizedRoot.path
                var progress = ScanProgress()
                // The exhaustive browser reads file metadata on demand. The scanner only
                // needs directory totals, so retaining the legacy per-directory file heaps
                // would waste memory without contributing to the final snapshot or index.
                var aggregator = DirectoryAggregator(root: standardizedRoot, maxRetainedFileChildren: 0)
                var rootAccumulator = RootItemAccumulator(root: standardizedRoot)
                var topFiles = TopItemHeap(limit: topFileLimit)
                var categoryAccumulator = CategoryAccumulator()
                var cleanupAnalyzer = CleanupAnalyzer()
                var issues: [ScanIssue] = []
                var lastProgressAt = ContinuousClock.now
                var lastLiveSummaryAt = ContinuousClock.now
                var containerStack: [(path: String, category: ItemCategory)] = []

                if let rootContainer = FileTypeClassifier.containerCategory(for: standardizedRoot, isDirectory: true, isPackage: true) {
                    containerStack.append((standardizedRoot.path, rootContainer))
                }

                // Do not request totalFileSize/totalFileAllocatedSize here. On directories,
                // providers may recursively calculate descendants, turning one scan into many.
                // fileSize/fileAllocatedSize are the correct per-file values; folder totals are
                // produced exactly once by DirectoryAggregator.
                let keySet: Set<URLResourceKey> = [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                    .isHiddenKey, .fileSizeKey, .fileAllocatedSizeKey,
                    .contentModificationDateKey
                ]

                let errorBox = ErrorBox()
                guard let enumerator = FileManager.default.enumerator(
                    at: standardizedRoot,
                    includingPropertiesForKeys: Array(keySet),
                    options: [],
                    errorHandler: { url, error in
                        errorBox.append(url: url, error: error)
                        return true
                    }
                ) else {
                    let issue = ScanIssue(path: standardizedRoot.path, message: "Impossible d’ouvrir le volume.", isPermissionError: true)
                    progress.permissionErrors = 1
                    progress.skippedItems = 1
                    let snapshot = ScanSnapshot(
                        root: standardizedRoot,
                        progress: progress,
                        topFiles: [],
                        topDirectories: [],
                        directoryContents: [:],
                        issues: [issue],
                        completedAt: Date(),
                        scanID: scanID,
                        volumeID: volumeID,
                        indexVersion: Self.currentIndexVersion,
                        categoryReport: categoryAccumulator.makeReport(permissionErrors: 1, isComplete: false)
                    )
                    continuation.yield(.completed(snapshot))
                    continuation.finish()
                    return
                }

                func mergeErrors() {
                    let newErrors = errorBox.drain()
                    progress.permissionErrors = SaturatingArithmetic.addNonnegative(
                        progress.permissionErrors,
                        newErrors.lazy.filter(\.isPermissionError).count
                    )
                    progress.skippedItems = SaturatingArithmetic.addNonnegative(
                        progress.skippedItems,
                        newErrors.count
                    )
                    issues.append(contentsOf: newErrors.prefix(max(0, 500 - issues.count)))
                }

                // Cancellation must stay responsive even after millions of entries. Do not
                // resolve every directory here: the live root summary and categories already
                // carry the useful partial state, while the full directory fold belongs only
                // to finalization.
                func cancellationSnapshot() -> ScanSnapshot {
                    ScanSnapshot(
                        root: standardizedRoot,
                        progress: progress,
                        topFiles: topFiles.descending(),
                        topDirectories: [],
                        directoryContents: [:],
                        issues: Array((issues + errorBox.values).prefix(500)),
                        completedAt: nil,
                        scanID: scanID,
                        volumeID: volumeID,
                        indexVersion: Self.currentIndexVersion,
                        categoryReport: categoryAccumulator.makeReport(permissionErrors: progress.permissionErrors, isComplete: false)
                    )
                }

                func finalSnapshot(completedAt: Date?) async -> ScanSnapshot {
                    let allDirectories = aggregator.takeDirectoryItems()
                    var directoryHeap = TopItemHeap(limit: topDirectoryLimit)
                    for directory in allDirectories { directoryHeap.insert(directory) }
                    do {
                        let index = try DirectoryIndexStore(volumeID: volumeID, root: standardizedRoot)
                        let summaries = allDirectories.map { DirectorySummary(item: $0, volumeID: volumeID) }
                        try await index.replaceAll(
                            summaries,
                            scanID: scanID,
                            indexVersion: DirectoryIndexStore.schemaVersion
                        )
                    } catch {
                        if issues.count < 500 {
                            issues.append(ScanIssue(
                                path: standardizedRoot.path,
                                message: "L’index de navigation n’a pas pu être enregistré : \(error.localizedDescription)",
                                isPermissionError: false
                            ))
                        }
                    }
                    return ScanSnapshot(
                        root: standardizedRoot,
                        progress: progress,
                        topFiles: topFiles.descending(),
                        topDirectories: directoryHeap.descending(),
                        directoryContents: [:],
                        issues: Array((issues + errorBox.values).prefix(500)),
                        cleanupReport: cleanupAnalyzer.makeReport(directories: allDirectories, permissionErrors: progress.permissionErrors, isComplete: true),
                        completedAt: completedAt,
                        scanID: scanID,
                        volumeID: volumeID,
                        indexVersion: DirectoryIndexStore.schemaVersion,
                        categoryReport: categoryAccumulator.makeReport(permissionErrors: progress.permissionErrors, isComplete: true)
                    )
                }

                while let candidate = enumerator.nextObject() as? URL {
                    if Task.isCancelled {
                        mergeErrors()
                        continuation.yield(.cancelled(cancellationSnapshot()))
                        continuation.finish()
                        return
                    }

                    progress.currentPath = candidate.path
                    // `/` exposes other mounted disks under /Volumes and duplicate APFS views
                    // under /System/Volumes. Canonical firmlinks such as /Users are still visited.
                    if standardizedRoot.path == "/" && (candidate.path == "/Volumes" || candidate.path == "/System/Volumes") {
                        enumerator.skipDescendants()
                        progress.skippedItems = SaturatingArithmetic.addNonnegative(progress.skippedItems, 1)
                        continue
                    }

                    do {
                        let values = try autoreleasepool {
                            try candidate.resourceValues(forKeys: keySet)
                        }
                        if values.isSymbolicLink == true {
                            enumerator.skipDescendants()
                            progress.skippedItems = SaturatingArithmetic.addNonnegative(progress.skippedItems, 1)
                            continue
                        }

                        let isDirectory = values.isDirectory == true
                        let isPackage = values.isPackage == true
                        if isDirectory,
                           let rootDeviceID,
                           let candidateDeviceID = Self.deviceID(for: candidate),
                           candidateDeviceID != rootDeviceID {
                            enumerator.skipDescendants()
                            progress.skippedItems = SaturatingArithmetic.addNonnegative(progress.skippedItems, 1)
                            continue
                        }
                        let logical = isDirectory ? 0 : max(0, Int64(values.fileSize ?? 0))
                        let allocated = isDirectory ? 0 : max(0, Int64(values.fileAllocatedSize ?? values.fileSize ?? 0))
                        while let container = containerStack.last,
                              candidate.path != container.path,
                              !candidate.path.hasPrefix(container.path + "/") {
                            containerStack.removeLast()
                        }
                        let inheritedContainer = containerStack.last?.category
                        let ownContainer = FileTypeClassifier.containerCategory(for: candidate, isDirectory: isDirectory, isPackage: isPackage)
                        let category = FileTypeClassifier.category(
                            for: candidate,
                            isDirectory: isDirectory,
                            isPackage: isPackage,
                            inheritedContainerCategory: inheritedContainer,
                            inspectAncestorContainers: false
                        )
                        let item = FileSystemItem(
                            url: candidate,
                            logicalSize: logical,
                            allocatedSize: allocated,
                            isDirectory: isDirectory,
                            isPackage: isPackage,
                            isHidden: values.isHidden == true,
                            modificationDate: values.contentModificationDate,
                            category: category,
                            safety: FileTypeClassifier.safety(for: candidate, isDirectory: isDirectory)
                        )

                        if isDirectory {
                            progress.directoriesScanned = SaturatingArithmetic.addNonnegative(
                                progress.directoriesScanned, 1
                            )
                            aggregator.registerDirectory(item)
                            rootAccumulator.registerDirectory(item)
                            if let ownContainer {
                                containerStack.append((candidate.path, ownContainer))
                            }
                        } else if values.isRegularFile == true {
                            progress.filesScanned = SaturatingArithmetic.addNonnegative(progress.filesScanned, 1)
                            progress.logicalBytesDiscovered = SaturatingArithmetic.addNonnegative(
                                progress.logicalBytesDiscovered, logical
                            )
                            progress.allocatedBytesDiscovered = SaturatingArithmetic.addNonnegative(
                                progress.allocatedBytesDiscovered, allocated
                            )
                            aggregator.addFile(item)
                            rootAccumulator.addFile(item)
                            topFiles.insert(item)
                            categoryAccumulator.observe(item)
                            cleanupAnalyzer.observeFile(item)
                        } else {
                            progress.skippedItems = SaturatingArithmetic.addNonnegative(progress.skippedItems, 1)
                        }
                    } catch {
                        let issue = Self.issue(for: candidate, error: error)
                        if issue.isPermissionError {
                            progress.permissionErrors = SaturatingArithmetic.addNonnegative(
                                progress.permissionErrors, 1
                            )
                        }
                        progress.skippedItems = SaturatingArithmetic.addNonnegative(progress.skippedItems, 1)
                        if issues.count < 500 { issues.append(issue) }
                    }

                    let itemCount = SaturatingArithmetic.addNonnegative(
                        progress.filesScanned,
                        progress.directoriesScanned
                    )
                    // Avoid a clock syscall on every file while still keeping the UI lively.
                    if itemCount < 128 || itemCount & 127 == 0 {
                        let now = ContinuousClock.now
                        if now - lastProgressAt >= progressInterval {
                            mergeErrors()
                            continuation.yield(.progress(progress))
                            lastProgressAt = now
                        }

                        if now - lastLiveSummaryAt >= .seconds(1) {
                            continuation.yield(.live(ScanLiveSummary(
                                scanID: scanID,
                                volumeID: volumeID,
                                progress: progress,
                                categoryReport: categoryAccumulator.makeReport(permissionErrors: progress.permissionErrors, isComplete: false),
                                rootItems: rootAccumulator.items()
                            )))
                            lastLiveSummaryAt = now
                        }

                    }
                    // A full-volume enumeration can otherwise remain on one cooperative
                    // executor job for minutes. Yielding very occasionally drains temporary
                    // Foundation objects and lets cancellation/other user work run promptly.
                    if itemCount > 0, itemCount & 4_095 == 0 {
                        await Task.yield()
                    }
                }

                mergeErrors()
                continuation.yield(.progress(progress))
                continuation.yield(.finalizing(progress))
                let snapshot = await finalSnapshot(completedAt: Date())
                continuation.yield(.live(ScanLiveSummary(
                    scanID: scanID,
                    volumeID: volumeID,
                    progress: progress,
                    categoryReport: snapshot.categoryReport,
                    rootItems: rootAccumulator.items(),
                    isComplete: true
                )))
                continuation.yield(.completed(snapshot))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func issue(for url: URL, error: Error) -> ScanIssue {
        let nsError = error as NSError
        let denied = nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code)
        return ScanIssue(path: url.path, message: nsError.localizedDescription, isPermissionError: denied)
    }

    private static func canonicalURL(for url: URL) -> URL {
        url.withUnsafeFileSystemRepresentation { representation in
            guard let representation, let resolved = realpath(representation, nil) else {
                return url.standardizedFileURL
            }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }

    private static func deviceID(for url: URL) -> UInt64? {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return lstat(representation, &information)
        }
        return result == 0 ? FileIdentity.deviceID(fromRawValue: information.st_dev) : nil
    }
}

/// Incremental root-only summary for live UI. Its storage is proportional to the
/// number of direct root children, never to the number of scanned descendants.
private struct RootItemAccumulator {
    private struct State {
        var item: FileSystemItem
        var logicalSize: Int64
        var allocatedSize: Int64
        var isDirectFile: Bool
    }

    private let root: URL
    private let rootPath: String
    private var states: [String: State] = [:]

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.rootPath = root.standardizedFileURL.path
    }

    mutating func registerDirectory(_ item: FileSystemItem) {
        guard item.parentPath == rootPath else { return }
        let existing = states[item.url.path]
        states[item.url.path] = State(
            item: item,
            logicalSize: existing?.logicalSize ?? 0,
            allocatedSize: existing?.allocatedSize ?? 0,
            isDirectFile: false
        )
    }

    mutating func addFile(_ item: FileSystemItem) {
        guard let childPath = directChildPath(containing: item.url.path) else { return }
        if childPath == item.url.path {
            states[childPath] = State(
                item: item,
                logicalSize: item.logicalSize,
                allocatedSize: item.allocatedSize,
                isDirectFile: true
            )
            return
        }

        let existing = states[childPath]
        let childURL = URL(fileURLWithPath: childPath, isDirectory: true)
        let base = existing?.item ?? FileSystemItem(
            url: childURL,
            logicalSize: 0,
            allocatedSize: 0,
            isDirectory: true,
            category: FileTypeClassifier.category(for: childURL, isDirectory: true, isPackage: false),
            safety: FileTypeClassifier.safety(for: childURL, isDirectory: true)
        )
        states[childPath] = State(
            item: base,
            logicalSize: saturatingAdd(existing?.logicalSize ?? 0, max(0, item.logicalSize)),
            allocatedSize: saturatingAdd(existing?.allocatedSize ?? 0, max(0, item.allocatedSize)),
            isDirectFile: false
        )
    }

    func items() -> [FileSystemItem] {
        states.values.map { state in
            guard !state.isDirectFile else { return state.item }
            return FileSystemItem(
                url: state.item.url,
                name: state.item.name,
                logicalSize: state.logicalSize,
                allocatedSize: state.allocatedSize,
                isDirectory: true,
                isSymbolicLink: state.item.isSymbolicLink,
                isPackage: state.item.isPackage,
                isHidden: state.item.isHidden,
                creationDate: state.item.creationDate,
                modificationDate: state.item.modificationDate,
                category: state.item.category,
                safety: state.item.safety
            )
        }.sorted {
            if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func directChildPath(containing path: String) -> String? {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix), path != rootPath else { return nil }
        let relative = path.dropFirst(prefix.count)
        guard !relative.isEmpty else { return nil }
        let name = relative.prefix { $0 != "/" }
        return rootPath == "/" ? "/" + name : root.appendingPathComponent(String(name)).path
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanIssue] = []

    var values: [ScanIssue] { lock.withLock { storage } }

    func append(url: URL, error: Error) {
        let nsError = error as NSError
        let denied = nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code)
        lock.withLock {
            if storage.count < 500 {
                storage.append(ScanIssue(path: url.path, message: nsError.localizedDescription, isPermissionError: denied))
            }
        }
    }

    func drain() -> [ScanIssue] {
        lock.withLock {
            let result = storage
            storage.removeAll(keepingCapacity: true)
            return result
        }
    }
}
