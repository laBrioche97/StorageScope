import Darwin
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum DuplicateAnalysisPhase: String, Codable, Sendable {
    case enumerating
    case sampleHashing
    case fullHashing
    case finalizing
}

public struct DuplicateAnalysisProgress: Hashable, Codable, Sendable {
    public var phase: DuplicateAnalysisPhase
    public var filesScanned: Int
    public var candidateFiles: Int
    public var groupsFound: Int
    public var bytesHashed: Int64
    public var totalBytesToHash: Int64
    public var currentPath: String
    public var skippedSensitiveItems: Int
    public var skippedCloudItems: Int
    public var skippedHardLinks: Int
    public var skippedUnreadableItems: Int
    public var startedAt: Date

    public init(
        phase: DuplicateAnalysisPhase = .enumerating, filesScanned: Int = 0,
        candidateFiles: Int = 0, groupsFound: Int = 0, bytesHashed: Int64 = 0,
        totalBytesToHash: Int64 = 0, currentPath: String = "",
        skippedSensitiveItems: Int = 0, skippedCloudItems: Int = 0,
        skippedHardLinks: Int = 0, skippedUnreadableItems: Int = 0,
        startedAt: Date = Date()
    ) {
        self.phase = phase
        self.filesScanned = filesScanned
        self.candidateFiles = candidateFiles
        self.groupsFound = groupsFound
        self.bytesHashed = bytesHashed
        self.totalBytesToHash = totalBytesToHash
        self.currentPath = currentPath
        self.skippedSensitiveItems = skippedSensitiveItems
        self.skippedCloudItems = skippedCloudItems
        self.skippedHardLinks = skippedHardLinks
        self.skippedUnreadableItems = skippedUnreadableItems
        self.startedAt = startedAt
    }
}

public struct DuplicateFile: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.standardizedFileURL.path }
    public let url: URL
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let modificationDate: Date?
    public let identity: FileIdentity

    public init(
        url: URL, logicalSize: Int64, allocatedSize: Int64,
        modificationDate: Date?, identity: FileIdentity
    ) {
        self.url = url
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.identity = identity
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let contentHash: String
    public let logicalSizePerFile: Int64
    public let files: [DuplicateFile]
    public let reclaimableBytesUpperBound: Int64
    public let minimumCopiesToKeep: Int

    public init(
        id: String, contentHash: String, logicalSizePerFile: Int64,
        files: [DuplicateFile], reclaimableBytesUpperBound: Int64,
        minimumCopiesToKeep: Int = 1
    ) {
        self.id = id
        self.contentHash = contentHash
        self.logicalSizePerFile = logicalSizePerFile
        self.files = files
        self.reclaimableBytesUpperBound = reclaimableBytesUpperBound
        self.minimumCopiesToKeep = max(1, minimumCopiesToKeep)
    }
}

public struct DuplicateAnalysisReport: Sendable {
    public let root: URL
    public let minimumSize: Int64
    public let groups: [DuplicateGroup]
    public let progress: DuplicateAnalysisProgress
    public let completedAt: Date
    public let isComplete: Bool

    public var reclaimableBytesUpperBound: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytesUpperBound }
    }

    public init(
        root: URL, minimumSize: Int64, groups: [DuplicateGroup],
        progress: DuplicateAnalysisProgress, completedAt: Date = Date(), isComplete: Bool
    ) {
        self.root = root
        self.minimumSize = minimumSize
        self.groups = groups
        self.progress = progress
        self.completedAt = completedAt
        self.isComplete = isComplete
    }
}

public enum DuplicateAnalysisEvent: Sendable {
    case progress(DuplicateAnalysisProgress)
    case completed(DuplicateAnalysisReport)
    case cancelled(DuplicateAnalysisProgress)
    case failed(String)
}

public enum DuplicateSelectionError: LocalizedError, Sendable {
    case unknownFile(String)
    case mustKeepOneCopy
    case fileChanged(String)

    public var errorDescription: String? {
        switch self {
        case .unknownFile(let path): "Le fichier ne fait pas partie de ce groupe : \(path)"
        case .mustKeepOneCopy: "Au moins une copie doit être conservée."
        case .fileChanged(let path): "Le fichier a changé depuis l’analyse : \(path)"
        }
    }
}

public struct DuplicateAnalysisService: @unchecked Sendable {
    private struct Candidate: Sendable {
        let file: DuplicateFile
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private struct FileState {
        let identity: FileIdentity
        let linkCount: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private enum HashingError: LocalizedError {
        case cryptoUnavailable
        case identityChanged

        var errorDescription: String? {
            switch self {
            case .cryptoUnavailable: "SHA-256 n’est pas disponible sur ce système."
            case .identityChanged: "Le fichier a changé pendant l’analyse."
            }
        }
    }

    private let fileManager: FileManager
    private let homePath: String
    private let sampleByteCount: Int
    private let hashingChunkSize: Int

    public init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        sampleByteCount: Int = 64 * 1_024,
        hashingChunkSize: Int = 1_024 * 1_024
    ) {
        self.fileManager = fileManager
        self.homePath = homeURL.standardizedFileURL.path
        self.sampleByteCount = max(4_096, sampleByteCount)
        self.hashingChunkSize = max(64 * 1_024, hashingChunkSize)
    }

    /// The stream owns its task. Cancelling the consumer cancels enumeration and hashing.
    public func events(
        root: URL,
        minimumSize: Int64 = 10 * 1_048_576
    ) -> AsyncStream<DuplicateAnalysisEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(root: root, minimumSize: max(1, minimumSize), continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func analyze(
        root: URL,
        minimumSize: Int64 = 10 * 1_048_576
    ) async -> DuplicateAnalysisReport {
        var latestProgress = DuplicateAnalysisProgress()
        for await event in events(root: root, minimumSize: minimumSize) {
            switch event {
            case .progress(let progress), .cancelled(let progress): latestProgress = progress
            case .completed(let report): return report
            case .failed: break
            }
        }
        return DuplicateAnalysisReport(
            root: root, minimumSize: minimumSize, groups: [],
            progress: latestProgress, isComplete: false
        )
    }

    /// Revalidates a user's explicit selection immediately before it is handed to
    /// `TrashService`. No file is selected implicitly and at least one verified copy remains.
    public func validatedTrashItems(
        in group: DuplicateGroup,
        selectedFileIDs: Set<String>
    ) async throws -> [FileSystemItem] {
        guard !selectedFileIDs.isEmpty else { return [] }
        let knownIDs = Set(group.files.map(\.id))
        if let unknown = selectedFileIDs.first(where: { !knownIDs.contains($0) }) {
            throw DuplicateSelectionError.unknownFile(unknown)
        }
        guard group.files.count - selectedFileIDs.count >= group.minimumCopiesToKeep else {
            throw DuplicateSelectionError.mustKeepOneCopy
        }

        let selected = group.files.filter { selectedFileIDs.contains($0.id) }
        let retained = group.files.filter { !selectedFileIDs.contains($0.id) }
        // Revalidate one retained copy as well as every deletion candidate. This ensures
        // the user is not left with an unverified file after a stale analysis result.
        for file in selected + retained.prefix(1) {
            if Task.isCancelled { throw CancellationError() }
            let before = try fileState(at: file.url)
            guard before.identity == file.identity, before.size == file.logicalSize, before.linkCount <= 1 else {
                throw DuplicateSelectionError.fileChanged(file.url.path)
            }
            let digest = try fullHash(of: file.url) { _ in }
            let after = try fileState(at: file.url)
            guard after.identity == before.identity, after.size == before.size,
                  after.modificationSeconds == before.modificationSeconds,
                  after.modificationNanoseconds == before.modificationNanoseconds,
                  digest == group.contentHash else {
                throw DuplicateSelectionError.fileChanged(file.url.path)
            }
        }

        return selected.map { file in
            FileSystemItem(
                url: file.url, logicalSize: file.logicalSize, allocatedSize: file.allocatedSize,
                isDirectory: false, modificationDate: file.modificationDate,
                category: .other, safety: .personal
            )
        }
    }

    private func run(
        root: URL, minimumSize: Int64,
        continuation: AsyncStream<DuplicateAnalysisEvent>.Continuation
    ) async {
        var progress = DuplicateAnalysisProgress()
        var candidatesBySize: [Int64: [Candidate]] = [:]
        var lastEmission = Date.distantPast

        if isSensitiveDirectory(root) {
            continuation.yield(.failed("Cette bibliothèque, sauvegarde ou zone système est volontairement exclue."))
            continuation.finish()
            return
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
            .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in true }
        ) else {
            continuation.yield(.failed("Impossible d’énumérer \(root.path)."))
            continuation.finish()
            return
        }

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                continuation.yield(.cancelled(progress))
                continuation.finish()
                return
            }
            progress.currentPath = url.path
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isDirectory == true {
                    if values.isSymbolicLink == true || values.isPackage == true || isSensitiveDirectory(url) {
                        enumerator.skipDescendants()
                        progress.skippedSensitiveItems += 1
                    }
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                progress.filesScanned += 1

                guard Int64(values.fileSize ?? 0) >= minimumSize else { continue }
                if isSensitiveFile(url) {
                    progress.skippedSensitiveItems += 1
                    continue
                }
                if isCloudPlaceholder(url, downloadingStatus: values.ubiquitousItemDownloadingStatus) {
                    progress.skippedCloudItems += 1
                    continue
                }
                let state = try fileState(at: url)
                guard state.size >= minimumSize else { continue }
                guard state.linkCount <= 1 else {
                    progress.skippedHardLinks += 1
                    continue
                }
                let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                let file = DuplicateFile(
                    url: url, logicalSize: state.size, allocatedSize: allocated,
                    modificationDate: values.contentModificationDate, identity: state.identity
                )
                candidatesBySize[state.size, default: []].append(Candidate(
                    file: file, modificationSeconds: state.modificationSeconds,
                    modificationNanoseconds: state.modificationNanoseconds
                ))
            } catch {
                progress.skippedUnreadableItems += 1
            }

            if Date().timeIntervalSince(lastEmission) >= 0.2 {
                progress.candidateFiles = candidatesBySize.values.reduce(0) { $0 + $1.count }
                continuation.yield(.progress(progress))
                lastEmission = Date()
            }
        }

        let sizeGroups = candidatesBySize.values.filter { $0.count > 1 }
        progress.candidateFiles = sizeGroups.reduce(0) { $0 + $1.count }
        progress.phase = .sampleHashing
        progress.totalBytesToHash = sizeGroups.reduce(0) { total, group in
            total + group.reduce(0) { $0 + sampleBytes(for: $1.file.logicalSize) }
        }
        continuation.yield(.progress(progress))

        var sampleGroups: [[Candidate]] = []
        for sizeGroup in sizeGroups {
            var bySample: [String: [Candidate]] = [:]
            for candidate in sizeGroup {
                if Task.isCancelled {
                    continuation.yield(.cancelled(progress)); continuation.finish(); return
                }
                progress.currentPath = candidate.file.url.path
                do {
                    guard try isUnchanged(candidate) else {
                        throw HashingError.identityChanged
                    }
                    let digest = try sampleHash(of: candidate.file.url, size: candidate.file.logicalSize)
                    guard try isUnchanged(candidate) else {
                        throw HashingError.identityChanged
                    }
                    bySample[digest, default: []].append(candidate)
                    progress.bytesHashed += sampleBytes(for: candidate.file.logicalSize)
                } catch is CancellationError {
                    continuation.yield(.cancelled(progress)); continuation.finish(); return
                } catch {
                    progress.skippedUnreadableItems += 1
                }
                emitProgressIfNeeded(&progress, lastEmission: &lastEmission, continuation: continuation)
            }
            sampleGroups.append(contentsOf: bySample.values.filter { $0.count > 1 })
        }

        progress.phase = .fullHashing
        progress.totalBytesToHash = progress.bytesHashed + sampleGroups.reduce(0) { total, group in
            total + group.reduce(0) { $0 + $1.file.logicalSize }
        }
        continuation.yield(.progress(progress))

        var duplicateGroups: [DuplicateGroup] = []
        for sampleGroup in sampleGroups {
            var byFullHash: [String: [Candidate]] = [:]
            for candidate in sampleGroup {
                if Task.isCancelled {
                    continuation.yield(.cancelled(progress)); continuation.finish(); return
                }
                progress.currentPath = candidate.file.url.path
                do {
                    guard try isUnchanged(candidate) else {
                        throw HashingError.identityChanged
                    }
                    let digest = try fullHash(of: candidate.file.url) { bytes in
                        progress.bytesHashed += Int64(bytes)
                        emitProgressIfNeeded(&progress, lastEmission: &lastEmission, continuation: continuation)
                    }
                    guard try isUnchanged(candidate) else {
                        throw HashingError.identityChanged
                    }
                    byFullHash[digest, default: []].append(candidate)
                } catch is CancellationError {
                    continuation.yield(.cancelled(progress)); continuation.finish(); return
                } catch {
                    progress.skippedUnreadableItems += 1
                }
            }

            for (digest, matching) in byFullHash where matching.count > 1 {
                let files = matching.map(\.file).sorted {
                    $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                let reclaimable = files.dropFirst().reduce(0) { $0 + $1.allocatedSize }
                duplicateGroups.append(DuplicateGroup(
                    id: "\(files[0].logicalSize):\(digest)", contentHash: digest,
                    logicalSizePerFile: files[0].logicalSize, files: files,
                    reclaimableBytesUpperBound: reclaimable
                ))
                progress.groupsFound += 1
            }
        }

        progress.phase = .finalizing
        progress.currentPath = root.path
        continuation.yield(.progress(progress))
        duplicateGroups.sort {
            if $0.reclaimableBytesUpperBound != $1.reclaimableBytesUpperBound {
                return $0.reclaimableBytesUpperBound > $1.reclaimableBytesUpperBound
            }
            return $0.id < $1.id
        }
        continuation.yield(.completed(DuplicateAnalysisReport(
            root: root, minimumSize: minimumSize, groups: duplicateGroups,
            progress: progress, isComplete: true
        )))
        continuation.finish()
    }

    private func emitProgressIfNeeded(
        _ progress: inout DuplicateAnalysisProgress, lastEmission: inout Date,
        continuation: AsyncStream<DuplicateAnalysisEvent>.Continuation
    ) {
        guard Date().timeIntervalSince(lastEmission) >= 0.2 else { return }
        continuation.yield(.progress(progress))
        lastEmission = Date()
    }

    private func isSensitiveDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let deniedRoots = [
            "/System", "/Library", "/private", "/usr", "/bin", "/sbin",
            homePath + "/Library/Mail", homePath + "/Library/Messages",
            homePath + "/Library/MobileSync/Backup", homePath + "/Library/Photos",
            homePath + "/Pictures/Photos Library.photoslibrary"
        ]
        return deniedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
            || sensitivePackageExtensions.contains(url.pathExtension.lowercased())
    }

    private func isSensitiveFile(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/.git/")
            || path.contains("/Backups.backupdb/")
            || path.hasPrefix(homePath + "/Library/Keychains/")
    }

    private var sensitivePackageExtensions: Set<String> {
        ["app", "photoslibrary", "photolibrary", "musiclibrary", "imovielibrary",
         "fcpbundle", "vmwarevm", "pvm", "utm", "sparsebundle", "backupdb"]
    }

    private func isCloudPlaceholder(_ url: URL, downloadingStatus: URLUbiquitousItemDownloadingStatus?) -> Bool {
        guard fileManager.isUbiquitousItem(at: url) else { return false }
        return downloadingStatus != .current
    }

    private func fileState(at url: URL) throws -> FileState {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &information)
        }
        guard result == 0, information.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        return FileState(
            identity: FileIdentity(deviceID: FileIdentity.deviceID(fromRawValue: information.st_dev), inode: UInt64(information.st_ino),
                fileType: UInt16(information.st_mode & S_IFMT)),
            linkCount: UInt64(information.st_nlink),
            size: Int64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }

    private func isUnchanged(_ candidate: Candidate) throws -> Bool {
        let current = try fileState(at: candidate.file.url)
        return current.identity == candidate.file.identity
            && current.size == candidate.file.logicalSize
            && current.modificationSeconds == candidate.modificationSeconds
            && current.modificationNanoseconds == candidate.modificationNanoseconds
    }

    private func sampleBytes(for size: Int64) -> Int64 {
        min(size, Int64(sampleByteCount * 2))
    }

    private func sampleHash(of url: URL, size: Int64) throws -> String {
#if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let first = try handle.read(upToCount: sampleByteCount) ?? Data()
        var hasher = SHA256()
        hasher.update(data: first)
        if size > Int64(sampleByteCount) {
            let offset = UInt64(max(Int64(sampleByteCount), size - Int64(sampleByteCount)))
            try handle.seek(toOffset: offset)
            hasher.update(data: try handle.read(upToCount: sampleByteCount) ?? Data())
        }
        return hexDigest(hasher.finalize())
#else
        throw HashingError.cryptoUnavailable
#endif
    }

    private func fullHash(of url: URL, didRead: (Int) -> Void) throws -> String {
#if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let data = try handle.read(upToCount: hashingChunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            didRead(data.count)
        }
        return hexDigest(hasher.finalize())
#else
        throw HashingError.cryptoUnavailable
#endif
    }

#if canImport(CryptoKit)
    private func hexDigest<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
#endif
}
