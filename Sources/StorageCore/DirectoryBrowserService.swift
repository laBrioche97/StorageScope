import Darwin
import Foundation

public struct DirectoryBrowseOptions: Hashable, Sendable {
    /// Hidden files participate in storage totals, so the exhaustive browser includes
    /// them by default. The UI can still hide them without issuing another disk read.
    public var includeHidden: Bool
    public var batchSize: Int
    /// Packages stay atomic unless the user explicitly chooses “Afficher le contenu”.
    public var allowPackageTraversal: Bool

    public init(
        includeHidden: Bool = true,
        batchSize: Int = 256,
        allowPackageTraversal: Bool = false
    ) {
        self.includeHidden = includeHidden
        self.batchSize = max(1, batchSize)
        self.allowPackageTraversal = allowPackageTraversal
    }
}

public enum DirectoryBrowseEvent: Sendable {
    case started(directory: URL)
    case batch(directory: URL, items: [FileSystemItem])
    case issue(ScanIssue)
    case completed(directory: URL, totalItems: Int)
    case cancelled(directory: URL, totalItems: Int)
}

/// Enumerates every direct child on demand and enriches directories with indexed sizes.
///
/// It never follows symbolic links, never recursively walks a package implicitly and
/// does not cross into another mounted volume. Batches are not dropped by the stream,
/// which prevents the UI from silently losing children in very large directories.
public struct DirectoryBrowserService: Sendable {
    public let volumeID: String
    public let root: URL
    public let indexStore: DirectoryIndexStore

    public init(volumeID: String, root: URL, indexStore: DirectoryIndexStore) {
        self.volumeID = volumeID
        self.root = root.standardizedFileURL
        self.indexStore = indexStore
    }

    public func browse(
        directory: URL,
        options: DirectoryBrowseOptions = DirectoryBrowseOptions()
    ) -> AsyncStream<DirectoryBrowseEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) { [volumeID, root, indexStore] in
                let requested = directory.standardizedFileURL
                continuation.yield(.started(directory: requested))
                var emittedCount = 0

                func finishWithIssue(_ message: String, permission: Bool = false) {
                    continuation.yield(.issue(ScanIssue(
                        path: requested.path,
                        message: message,
                        isPermissionError: permission
                    )))
                    continuation.yield(.completed(directory: requested, totalItems: emittedCount))
                    continuation.finish()
                }

                guard volumeID == indexStore.volumeID, root.path == indexStore.root.path else {
                    finishWithIssue("Le navigateur et l’index ne ciblent pas le même volume.")
                    return
                }
                guard Self.isInsideRoot(requested.path, rootPath: root.path) else {
                    finishWithIssue("Ce dossier se trouve hors du volume sélectionné.")
                    return
                }
                guard !Self.isExcludedMountNamespace(requested.path, rootPath: root.path) else {
                    finishWithIssue("Les volumes montés sont analysés séparément pour éviter les doublons.")
                    return
                }

                let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
                let resolvedRequested = requested.resolvingSymlinksInPath().standardizedFileURL
                guard Self.isInsideRoot(resolvedRequested.path, rootPath: resolvedRoot.path) else {
                    finishWithIssue("Un lien symbolique mène hors du volume sélectionné.")
                    return
                }
                if requested.path != root.path && resolvedRequested.path != requested.path {
                    finishWithIssue("StorageScope n’ouvre pas les dossiers à travers un lien symbolique.")
                    return
                }

                let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
                do {
                    let values = try requested.resourceValues(forKeys: directoryKeys)
                    guard values.isSymbolicLink != true else {
                        finishWithIssue("StorageScope n’ouvre pas les liens symboliques.")
                        return
                    }
                    guard values.isDirectory == true else {
                        finishWithIssue("L’élément sélectionné n’est pas un dossier.")
                        return
                    }
                    if values.isPackage == true && requested.path != root.path && !options.allowPackageTraversal {
                        finishWithIssue("Ce paquet reste fermé. Utilisez « Afficher le contenu » pour l’explorer.")
                        return
                    }
                } catch {
                    let issue = Self.issue(for: requested, error: error)
                    finishWithIssue(issue.message, permission: issue.isPermissionError)
                    return
                }

                let keys: Set<URLResourceKey> = [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                    .isHiddenKey, .fileSizeKey, .fileAllocatedSizeKey,
                    .creationDateKey, .contentModificationDateKey
                ]
                var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
                if !options.includeHidden { enumerationOptions.insert(.skipsHiddenFiles) }
                let errorBox = DirectoryBrowseErrorBox()
                guard let enumerator = FileManager.default.enumerator(
                    at: requested,
                    includingPropertiesForKeys: Array(keys),
                    options: enumerationOptions,
                    errorHandler: { url, error in
                        errorBox.append(Self.issue(for: url, error: error))
                        return true
                    }
                ) else {
                    finishWithIssue("Impossible d’ouvrir ce dossier.", permission: true)
                    return
                }

                let rootDevice = Self.deviceID(for: root)
                var pending: [FileSystemItem] = []
                pending.reserveCapacity(options.batchSize)

                while let child = enumerator.nextObject() as? URL {
                    if Task.isCancelled {
                        for issue in errorBox.drain() { continuation.yield(.issue(issue)) }
                        continuation.yield(.cancelled(directory: requested, totalItems: emittedCount))
                        continuation.finish()
                        return
                    }

                    let candidate = child.standardizedFileURL
                    guard Self.isInsideRoot(candidate.path, rootPath: root.path),
                          !Self.isExcludedMountNamespace(candidate.path, rootPath: root.path) else {
                        continue
                    }
                    if let rootDevice,
                       let childDevice = Self.deviceID(for: candidate),
                       childDevice != rootDevice {
                        continuation.yield(.issue(ScanIssue(
                            path: candidate.path,
                            message: "Ce point de montage appartient à un autre volume et a été ignoré.",
                            isPermissionError: false
                        )))
                        continue
                    }

                    do {
                        let values = try candidate.resourceValues(forKeys: keys)
                        let isSymbolicLink = values.isSymbolicLink == true
                        let isDirectory = values.isDirectory == true
                        let isPackage = isDirectory && values.isPackage == true
                        let logicalSize = isDirectory || isSymbolicLink ? 0 : Int64(values.fileSize ?? 0)
                        let allocatedSize = isDirectory || isSymbolicLink
                            ? 0
                            : Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)

                        guard isDirectory || values.isRegularFile == true || isSymbolicLink else { continue }
                        pending.append(FileSystemItem(
                            url: candidate,
                            logicalSize: logicalSize,
                            allocatedSize: allocatedSize,
                            isDirectory: isDirectory,
                            isSymbolicLink: isSymbolicLink,
                            isPackage: isPackage,
                            isHidden: values.isHidden == true,
                            creationDate: values.creationDate,
                            modificationDate: values.contentModificationDate,
                            category: FileTypeClassifier.category(
                                for: candidate,
                                isDirectory: isDirectory,
                                isPackage: isPackage
                            ),
                            safety: FileTypeClassifier.safety(for: candidate, isDirectory: isDirectory)
                        ))
                    } catch {
                        continuation.yield(.issue(Self.issue(for: candidate, error: error)))
                    }

                    if pending.count >= options.batchSize {
                        let batch = pending
                        pending.removeAll(keepingCapacity: true)
                        do {
                            let merged = try await Self.mergeIndexedSizes(into: batch, indexStore: indexStore)
                            emittedCount += merged.count
                            continuation.yield(.batch(directory: requested, items: merged))
                        } catch {
                            continuation.yield(.issue(ScanIssue(
                                path: requested.path,
                                message: "Les tailles indexées sont indisponibles : \(error.localizedDescription)",
                                isPermissionError: false
                            )))
                            emittedCount += batch.count
                            continuation.yield(.batch(directory: requested, items: batch))
                        }
                    }

                    for issue in errorBox.drain() { continuation.yield(.issue(issue)) }
                }

                if !pending.isEmpty {
                    do {
                        let merged = try await Self.mergeIndexedSizes(into: pending, indexStore: indexStore)
                        emittedCount += merged.count
                        continuation.yield(.batch(directory: requested, items: merged))
                    } catch {
                        continuation.yield(.issue(ScanIssue(
                            path: requested.path,
                            message: "Les tailles indexées sont indisponibles : \(error.localizedDescription)",
                            isPermissionError: false
                        )))
                        emittedCount += pending.count
                        continuation.yield(.batch(directory: requested, items: pending))
                    }
                }
                for issue in errorBox.drain() { continuation.yield(.issue(issue)) }
                continuation.yield(.completed(directory: requested, totalItems: emittedCount))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mergeIndexedSizes(
        into items: [FileSystemItem],
        indexStore: DirectoryIndexStore
    ) async throws -> [FileSystemItem] {
        let directoryPaths = items.lazy
            .filter { $0.isDirectory && !$0.isSymbolicLink }
            .map { $0.url.path }
        let summaries = try await indexStore.summaries(forPaths: Array(directoryPaths))
        guard !summaries.isEmpty else { return items }
        return items.map { item in
            guard let summary = summaries[item.url.path] else { return item }
            var enriched = item
            enriched.logicalSize = summary.logicalSize
            enriched.allocatedSize = summary.allocatedSize
            return enriched
        }
    }

    private static func isInsideRoot(_ path: String, rootPath: String) -> Bool {
        rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func isExcludedMountNamespace(_ path: String, rootPath: String) -> Bool {
        guard rootPath == "/" else { return false }
        return path == "/Volumes" || path.hasPrefix("/Volumes/")
            || path == "/System/Volumes" || path.hasPrefix("/System/Volumes/")
    }

    private static func deviceID(for url: URL) -> UInt64? {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return lstat(representation, &information)
        }
        return result == 0 ? FileIdentity.deviceID(fromRawValue: information.st_dev) : nil
    }

    private static func issue(for url: URL, error: Error) -> ScanIssue {
        let nsError = error as NSError
        let denied = nsError.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code)
        return ScanIssue(
            path: url.path,
            message: nsError.localizedDescription,
            isPermissionError: denied
        )
    }
}

private final class DirectoryBrowseErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [ScanIssue] = []

    func append(_ issue: ScanIssue) {
        lock.withLock {
            if issues.count < 1_000 { issues.append(issue) }
        }
    }

    func drain() -> [ScanIssue] {
        lock.withLock {
            let result = issues
            issues.removeAll(keepingCapacity: true)
            return result
        }
    }
}
