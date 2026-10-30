import CoreServices
import Darwin
import Foundation

public struct JournalSource: Codable, Equatable, Sendable {
    public init(device: UInt64, uuid: String, mountPath: String, watchPath: String, cursor: UInt64) {
        self.device = device; self.uuid = uuid; self.mountPath = mountPath; self.watchPath = watchPath; self.cursor = cursor
    }
    public let device: UInt64
    public let uuid: String
    public let mountPath: String
    public let watchPath: String
    public var cursor: UInt64
}

public struct JournalCheckpoint: Codable, Equatable, Sendable {
    public init(rootFingerprint: String, sources: [JournalSource]) { self.rootFingerprint = rootFingerprint; self.sources = sources }
    public let rootFingerprint: String
    public var sources: [JournalSource]

    public static func capture(root: URL) -> JournalCheckpoint? {
        var urls = [root]
        if root.path == "/" { urls.append(URL(fileURLWithPath: "/System/Volumes/Data")) }
        var sources: [JournalSource] = []
        for url in urls {
            guard let identity = ScanPathPolicy.identity(url), !sources.contains(where: { $0.device == identity.deviceID }) else { continue }
            let device = dev_t(bitPattern: UInt32(truncatingIfNeeded: identity.deviceID))
            guard let uuid = FSEventsCopyUUIDForDevice(device) else { continue }
            var info = statfs()
            guard statfs(url.path, &info) == 0 else { continue }
            let mount = withUnsafeBytes(of: info.f_mntonname) { bytes in String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            let watch = url.path == mount ? "/" : mount != "/" && url.path.hasPrefix(mount + "/") ? String(url.path.dropFirst(mount.count)) : url.path
            // This particular API uses POSIX seconds since 1970 despite its
            // CFAbsoluteTime parameter type (unlike CFAbsoluteTimeGetCurrent).
            sources.append(JournalSource(device: identity.deviceID, uuid: CFUUIDCreateString(nil, uuid) as String, mountPath: mount, watchPath: watch, cursor: FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970)))
        }
        guard !sources.isEmpty else { return nil }
        let uuid = (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? root.path
        // BSD disk numbers and dev_t change across boots. Only the sealed system
        // needs an OS-build token; data/external volumes are tracked by their UUID.
        let systemBuild = root.path == "/" ? ProcessInfo.processInfo.operatingSystemVersionString : nil
        return JournalCheckpoint(rootFingerprint: stableFingerprint(volumeUUID: uuid, systemBuild: systemBuild), sources: sources)
    }

    public static func stableFingerprint(volumeUUID: String, systemBuild: String? = nil) -> String {
        volumeUUID + (systemBuild.map { "|system:" + $0 } ?? "")
    }

    public func matches(_ current: JournalCheckpoint) -> Bool {
        rootFingerprint == current.rootFingerprint && sources.count == current.sources.count && zip(sources, current.sources).allSatisfy {
            $0.uuid == $1.uuid && $0.mountPath == $1.mountPath && $0.watchPath == $1.watchPath &&
            $0.cursor != UInt64.max && $1.cursor != UInt64.max && $0.cursor <= $1.cursor
        }
    }
}

public struct JournalChange: Sendable {
    public let path: String
    public let flags: UInt32
    public let id: UInt64
    public init(path: String, flags: UInt32, id: UInt64) { self.path = path; self.flags = flags; self.id = id }
}

public struct JournalBatch: Sendable {
    public init(source: Int, changes: [JournalChange]) { self.source = source; self.changes = changes }
    public let source: Int
    public let changes: [JournalChange]
}

private final class JournalCallback: @unchecked Sendable {
    let source: Int
    let continuation: AsyncStream<JournalBatch>.Continuation
    init(source: Int, continuation: AsyncStream<JournalBatch>.Continuation) { self.source = source; self.continuation = continuation }
}

/// Per-device streams retain their callback until invalidate/release, and deliver
/// losslessly on one queue. The consumer commits the cursor only after reconciliation.
public final class FileSystemJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [FSEventStreamRef] = []
    private let queue = DispatchQueue(label: "com.labrioche.StorageScope.journal", qos: .utility)
    public init() {}
    deinit { stop() }

    public func events(checkpoint: JournalCheckpoint, catchUp: JournalCheckpoint? = nil) -> AsyncStream<JournalBatch> {
        AsyncStream { continuation in
            lock.lock()
            for (index, source) in checkpoint.sources.enumerated() {
                let callback = Unmanaged.passRetained(JournalCallback(source: index, continuation: continuation))
                var context = FSEventStreamContext(version: 0, info: callback.toOpaque(), retain: nil, release: { pointer in
                    if let pointer { Unmanaged<JournalCallback>.fromOpaque(pointer).release() }
                }, copyDescription: nil)
                // Persistent journal chunks can straddle the saved cursor. FullHistory
                // includes that overlap after a process restart; replacements below
                // re-read the actual directory and are deliberately idempotent.
                let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFullHistory)
                guard let stream = FSEventStreamCreateRelativeToDevice(nil, { _, context, count, paths, flags, ids in
                    guard let context else { return }
                    let callback = Unmanaged<JournalCallback>.fromOpaque(context).takeUnretainedValue()
                    let names = unsafeBitCast(paths, to: CFArray.self) as! [String]
                    let changes = (0..<min(count, names.count)).map { JournalChange(path: names[$0], flags: flags[$0], id: ids[$0]) }
                    callback.continuation.yield(JournalBatch(source: callback.source, changes: changes))
                }, &context, dev_t(bitPattern: UInt32(truncatingIfNeeded: source.device)), [source.watchPath] as CFArray, source.cursor, 0.25, flags) else {
                    callback.release(); continuation.finish(); break
                }
                FSEventStreamSetDispatchQueue(stream, queue)
                guard FSEventStreamStart(stream) else {
                    FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); continuation.finish(); break
                }
                streams.append(stream)
                // A path with no matching historical changes may never emit
                // HistoryDone. Flush off the UI/callback queue, then enqueue an
                // explicit barrier for a cursor captured BEFORE starting the stream.
                FSEventStreamFlushSync(stream)
                let target = catchUp.flatMap { $0.sources.indices.contains(index) ? $0.sources[index].cursor : nil } ?? source.cursor
                continuation.yield(JournalBatch(source: index, changes: [JournalChange(path: "", flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: target)]))
            }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func stop() {
        let current = lock.withLock { let result = streams; streams = []; return result }
        for stream in current { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

public enum IndexFreshness: String, Sendable {
    case checking = "Vérification en cours"
    case updating = "Actualisation en cours"
    case current = "À jour"
    case partial = "Analyse partielle"
    case requiresScan = "Analyse nécessaire"
    case disconnected = "Stockage déconnecté"
}

public enum TreeSynchronizationEvent: Sendable {
    case status(IndexFreshness, String)
    case updated(TreeIndexState, settled: Bool)
}

public enum PersistentScanSynchronizer {
    public static func synchronize(root: URL, volumeID: String, observeChanges: (@Sendable (JournalBatch) -> Void)? = nil) -> AsyncStream<TreeSynchronizationEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task.detached(priority: .utility) {
                let journal = FileSystemJournal()
                defer { journal.stop(); continuation.finish() }
                do {
                    let store = try DirectoryIndexStore(volumeID: volumeID, root: root)
                    guard var state = try await store.treeState(), var checkpoint = state.checkpoint,
                          let current = JournalCheckpoint.capture(root: root), checkpoint.matches(current) else {
                        continuation.yield(.status(.requiresScan, "Une analyse complète initialise l’arborescence ou rétablit un journal incomplet.")); return
                    }
                    checkpoint.sources = zip(checkpoint.sources, current.sources).map { old, fresh in
                        JournalSource(device: fresh.device, uuid: fresh.uuid, mountPath: fresh.mountPath, watchPath: fresh.watchPath, cursor: old.cursor)
                    }
                    continuation.yield(.status(.checking, "Vérification des changements depuis la dernière utilisation…"))
                    continuation.yield(.updated(state, settled: false))
                    var caughtUp = Set<Int>()
                    for await batch in journal.events(checkpoint: checkpoint, catchUp: current) {
                        try Task.checkCancellation()
                        observeChanges?(batch)
                        let invalid = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount)
                        guard !batch.changes.contains(where: { $0.flags & invalid != 0 }) else {
                            continuation.yield(.status(.requiresScan, "Le journal ne permet plus de confirmer tous les changements. Relancez une analyse complète.")); return
                        }
                        let historyDone = batch.changes.contains { $0.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }
                        if historyDone { caughtUp.insert(batch.source) }
                        var paths = try replacements(for: batch, checkpoint: checkpoint, root: root)
                        if historyDone {
                            // Permission failures are retried without discarding their old tree.
                            paths += state.pending
                            paths += state.snapshot.issues.filter(\.isPermissionError).map { issue in
                                let url = URL(fileURLWithPath: issue.path)
                                if let identity = ScanPathPolicy.identity(url), identity.fileType == UInt16(S_IFREG) { return TreeReplacement(directory: url.deletingLastPathComponent(), recursive: false) }
                                return TreeReplacement(directory: url, recursive: true)
                            }
                        }
                        paths = coalesce(paths)
                        if !paths.isEmpty { continuation.yield(.status(.updating, "Actualisation de \(paths.count) dossier(s)…")) }
                        if let last = batch.changes.map(\.id).max() { checkpoint.sources[batch.source].cursor = max(checkpoint.sources[batch.source].cursor, last) }
                        if paths.isEmpty && !historyDone { continue }
                        let staged = UUID()
                        try await store.beginTreeGeneration(staged)
                        var valid: [TreeReplacement] = [], issues: [ScanIssue] = []
                        if !paths.isEmpty { await RecursiveReadBudget.shared.acquire() }
                        do {
                            for replacement in paths {
                                try Task.checkCancellation()
                                let result = try await readReplacement(replacement, root: root, store: store, staged: staged)
                                issues += result
                                if result.isEmpty { valid.append(replacement) }
                            }
                        } catch {
                            if !paths.isEmpty { await RecursiveReadBudget.shared.release() }
                            throw error
                        }
                        if !paths.isEmpty { await RecursiveReadBudget.shared.release() }
                        let failed = issues.isEmpty ? [] : paths
                        if !issues.isEmpty { try await store.discardTreeGeneration(staged); valid = [] }
                        let remaining = coalesce(state.pending + failed).filter { pending in
                            !valid.contains { $0.directory.path == pending.directory.path || $0.recursive && pending.directory.path.hasPrefix($0.directory.path + "/") }
                        }
                        state = try await store.applyTreeChanges(staged: staged, replacements: valid, checkpoint: checkpoint, issues: issues, pending: remaining)
                        continuation.yield(.updated(state, settled: caughtUp.count == checkpoint.sources.count))
                    }
                    if !Task.isCancelled { continuation.yield(.status(.requiresScan, "Le suivi du stockage s’est interrompu. Vérifiez le stockage puis relancez la vérification.")) }
                } catch is CancellationError {} catch {
                    continuation.yield(.status(.requiresScan, "Actualisation impossible : \(error.localizedDescription)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func replacements(for batch: JournalBatch, checkpoint: JournalCheckpoint, root: URL) throws -> [TreeReplacement] {
        let policy = ScanPathPolicy(root: root)
        let source = checkpoint.sources[batch.source]
        var result: [TreeReplacement] = []
        for change in batch.changes {
            if change.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let relative = change.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let physical = URL(fileURLWithPath: source.mountPath).appendingPathComponent(relative).standardized
            let path: URL
            if source.mountPath == "/System/Volumes/Data", !root.path.hasPrefix("/System/Volumes/Data/") { path = URL(fileURLWithPath: "/" + relative).standardized }
            else { path = physical }
            if policy.excludes(path) { continue }
            let isDirectory = change.flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            let recursive = change.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || isDirectory && change.flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
            if recursive, path.path == root.path, change.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { throw DirectoryIndexError.unavailable }
            result.append(TreeReplacement(directory: recursive || isDirectory ? path : path.deletingLastPathComponent(), recursive: recursive))
        }
        return coalesce(result)
    }

    public static func coalesce(_ paths: [TreeReplacement]) -> [TreeReplacement] {
        var result: [TreeReplacement] = []
        for path in paths.sorted(by: { $0.directory.path.count < $1.directory.path.count || ($0.directory.path == $1.directory.path && $0.recursive && !$1.recursive) }) {
            if result.contains(where: { $0.directory.path == path.directory.path || $0.recursive && path.directory.path.hasPrefix($0.directory.path == "/" ? "/" : $0.directory.path + "/") }) { continue }
            result.append(path)
        }
        return result
    }

    private static func readReplacement(_ replacement: TreeReplacement, root: URL, store: DirectoryIndexStore, staged: UUID) async throws -> [ScanIssue] {
        let policy = ScanPathPolicy(root: root)
        let directory = replacement.directory
        if ScanPathPolicy.identity(directory) == nil, !FileManager.default.fileExists(atPath: directory.path) {
            // Only ENOENT is a confirmed deletion, never an inaccessible directory.
            var info = stat()
            if lstat(directory.path, &info) != 0, errno == ENOENT { return [] }
        }
        if let identity = ScanPathPolicy.identity(directory), identity.fileType == UInt16(S_IFLNK) { return [] }
        if let identity = ScanPathPolicy.identity(directory), identity.fileType == UInt16(S_IFREG), !policy.excludes(directory) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .fileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey]
            try await store.appendTreeItems([try metadata(directory, keys: keys, policy: policy)], generation: staged)
            return []
        }
        do { try policy.validateDirectory(directory) } catch { return [ScanIssue(path: directory.path, message: "Le dossier n’est plus accessible ou a été remplacé.", isPermissionError: true)] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .fileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey]
        let failures = JournalReadErrors()
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: replacement.recursive ? [] : [.skipsSubdirectoryDescendants], errorHandler: { url, error in failures.append(ScanIssue(path: url.path, message: error.localizedDescription, isPermissionError: true)); return true }) else { return [ScanIssue(path: directory.path, message: "Lecture refusée.", isPermissionError: true)] }
        var pending: [FileSystemItem] = []
        pending.append(try metadata(directory, keys: keys, policy: policy))
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if policy.excludes(url) { enumerator.skipDescendants(); continue }
            do {
                let item = try metadata(url, keys: keys, policy: policy)
                guard let identity = item.indexedIdentity, identity.fileType == UInt16(S_IFREG) || identity.fileType == UInt16(S_IFDIR) || identity.fileType == UInt16(S_IFLNK) else { continue }
                if item.isSymbolicLink { continue }
                if !policy.acceptsDevice(identity) { if item.isDirectory { enumerator.skipDescendants() }; continue }
                pending.append(item)
                if !replacement.recursive, item.isDirectory,
                   try await store.summary(forPath: item.url.path) == nil {
                    failures.append(contentsOf: try await readReplacement(TreeReplacement(directory: url, recursive: true), root: root, store: store, staged: staged))
                }
                if pending.count >= 1024 { try await store.appendTreeItems(pending, generation: staged); pending.removeAll(keepingCapacity: true) }
            } catch is CancellationError { throw CancellationError() } catch { failures.append(ScanIssue(path: url.path, message: error.localizedDescription, isPermissionError: true)) }
        }
        try await store.appendTreeItems(pending, generation: staged)
        return failures.values
    }

    static func metadata(_ url: URL, keys: Set<URLResourceKey>, policy: ScanPathPolicy) throws -> FileSystemItem {
        let value = try url.resourceValues(forKeys: keys)
        let dir = value.isDirectory == true
        let identity = ScanPathPolicy.identity(url)
        return FileSystemItem(url: url, logicalSize: dir ? 0 : Int64(value.fileSize ?? 0), allocatedSize: dir ? 0 : Int64(value.fileAllocatedSize ?? value.fileSize ?? 0), isDirectory: dir, isSymbolicLink: value.isSymbolicLink == true, isPackage: value.isPackage == true, isHidden: value.isHidden == true, creationDate: value.creationDate, modificationDate: value.contentModificationDate, category: FileTypeClassifier.category(for: url, isDirectory: dir, isPackage: value.isPackage == true), safety: FileTypeClassifier.safety(for: url, isDirectory: dir), indexedIdentity: identity, indexedVolumeUUID: policy.volumeUUID(for: identity))
    }
}

private final class JournalReadErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScanIssue] = []
    var values: [ScanIssue] { lock.withLock { items } }
    func append(_ issue: ScanIssue) { lock.withLock { if items.count < 500 { items.append(issue) } } }
    func append(contentsOf issues: [ScanIssue]) { lock.withLock { items.append(contentsOf: issues.prefix(max(0, 500 - items.count))) } }
}
