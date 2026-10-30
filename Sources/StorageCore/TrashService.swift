import Darwin
import Foundation

public struct FileIdentity: Hashable, Codable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64
    public let fileType: UInt16

    public init(deviceID: UInt64, inode: UInt64, fileType: UInt16) {
        self.deviceID = deviceID
        self.inode = inode
        self.fileType = fileType
    }

    /// Darwin exposes `dev_t` as a signed 32-bit integer even though every bit is
    /// part of the opaque device identifier. A numeric UInt64 conversion traps when
    /// the high bit is set; preserving the raw bit pattern works for every volume.
    public static func deviceID(fromRawValue rawValue: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: rawValue))
    }
}

public enum TrashError: LocalizedError, Sendable {
    case protectedItem(String)
    case accessDenied(String)
    case missingItem(String)
    case identityChanged(String)
    case operationFailed(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .protectedItem(let path): "Élément système protégé : \(path)"
        case .accessDenied(let path): "macOS refuse l’accès à \(path). Vérifiez les droits de ce dossier dans le Finder et les autorisations de StorageScope dans Confidentialité et sécurité."
        case .missingItem(let path): "L’élément n’existe plus : \(path)"
        case .identityChanged(let path): "L’élément a changé depuis sa sélection : \(path)"
        case .operationFailed(let path, let message): "Impossible de déplacer \(path) : \(message)"
        }
    }
}

public enum TrashAuthorization: Hashable, Codable, Sendable {
    case userSelection
    case manualApplicationData
    case verifiedApplicationAssociation(bundleIdentifier: String)
}

public struct TrashPreflightResult: Identifiable, Sendable {
    public var id: String { item.id }
    public let item: FileSystemItem
    public let identity: FileIdentity?
    public let authorization: TrashAuthorization
    public let errorDescription: String?
    public var isReady: Bool { identity != nil && errorDescription == nil }

    public init(
        item: FileSystemItem, identity: FileIdentity?,
        authorization: TrashAuthorization = .userSelection,
        errorDescription: String?
    ) {
        self.item = item
        self.identity = identity
        self.authorization = authorization
        self.errorDescription = errorDescription
    }
}

public enum TrashOperationStatus: String, Codable, Sendable {
    case trashed
    case failed
    case skippedDuplicate
    case skippedCoveredByParent
    case cancelled
}

public struct TrashOperationResult: Identifiable, Sendable {
    public let id: UUID
    public let originalURL: URL
    public let resultingURL: URL?
    public let expectedIdentity: FileIdentity?
    public let status: TrashOperationStatus
    public let allocatedBytesUpperBound: Int64
    public let errorDescription: String?

    public init(
        id: UUID = UUID(), originalURL: URL, resultingURL: URL? = nil,
        expectedIdentity: FileIdentity? = nil, status: TrashOperationStatus,
        allocatedBytesUpperBound: Int64 = 0, errorDescription: String? = nil
    ) {
        self.id = id
        self.originalURL = originalURL
        self.resultingURL = resultingURL
        self.expectedIdentity = expectedIdentity
        self.status = status
        self.allocatedBytesUpperBound = allocatedBytesUpperBound
        self.errorDescription = errorDescription
    }
}

public struct TrashInventoryIssue: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case accessDenied, unsafeRoot, unavailable }
    public let id: UUID
    public let path: String
    public let message: String
    public let kind: Kind

    public init(id: UUID = UUID(), path: String, message: String, kind: Kind = .unavailable) {
        self.id = id
        self.path = path
        self.message = message
        self.kind = kind
    }

    public static func from(_ error: Error, path: String) -> Self {
        let cocoa = error as NSError
        let denied: Bool
        if let trash = error as? TrashError, case .accessDenied = trash { denied = true }
        else { denied = (cocoa.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(cocoa.code))
            || (cocoa.domain == NSCocoaErrorDomain && [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(cocoa.code)) }
        if let trash = error as? TrashError, case .protectedItem = trash {
            return Self(path: path, message: "La racine de corbeille ne correspond pas à un dossier sûr appartenant à votre compte.", kind: .unsafeRoot)
        }
        return Self(path: path, message: error.localizedDescription, kind: denied ? .accessDenied : .unavailable)
    }
}

public struct TrashInventoryItem: Identifiable, Hashable, Sendable {
    public var id: String { url.standardizedFileURL.path }
    public let url: URL
    public let trashRoot: URL
    public let identity: FileIdentity
    public let allocatedBytesUpperBound: Int64
    public let isDirectory: Bool
    public let sizeIsComplete: Bool

    public init(url: URL, trashRoot: URL, identity: FileIdentity, allocatedBytesUpperBound: Int64, isDirectory: Bool, sizeIsComplete: Bool = true) {
        self.url = url
        self.trashRoot = trashRoot
        self.identity = identity
        self.allocatedBytesUpperBound = allocatedBytesUpperBound
        self.isDirectory = isDirectory
        self.sizeIsComplete = sizeIsComplete
    }
}

public struct TrashInventory: Sendable {
    public let id = UUID()
    public let items: [TrashInventoryItem]
    public let issues: [TrashInventoryIssue]
    public let generatedAt: Date
    public let wasCancelled: Bool

    public var totalAllocatedBytesUpperBound: Int64 { items.reduce(0) { $0 + $1.allocatedBytesUpperBound } }
    public var requiresAccess: Bool { issues.contains { $0.kind == .accessDenied } }
    public var isPartial: Bool { !issues.isEmpty || wasCancelled || items.contains { !$0.sizeIsComplete } }
    public var hasMeasuredSize: Bool { !isPartial || items.contains { $0.sizeIsComplete || $0.allocatedBytesUpperBound > 0 } }

    public init(items: [TrashInventoryItem], issues: [TrashInventoryIssue], generatedAt: Date = Date(), wasCancelled: Bool = false) {
        self.items = items
        self.issues = issues
        self.generatedAt = generatedAt
        self.wasCancelled = wasCancelled
    }
}

public struct TrashEmptyAuthorization: Sendable {
    fileprivate let inventoryID: UUID
    /// Call only in the explicit destructive confirmation handler.
    public static func confirm(_ inventory: TrashInventory) -> Self { Self(inventoryID: inventory.id) }
}

public enum EmptyTrashItemStatus: String, Codable, Sendable {
    case deleted
    case failed
    case identityChanged
    case cancelled
}

public struct EmptyTrashItemResult: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let status: EmptyTrashItemStatus
    public let allocatedBytesUpperBound: Int64
    public let errorDescription: String?

    public init(id: UUID = UUID(), url: URL, status: EmptyTrashItemStatus, allocatedBytesUpperBound: Int64, errorDescription: String? = nil) {
        self.id = id
        self.url = url
        self.status = status
        self.allocatedBytesUpperBound = allocatedBytesUpperBound
        self.errorDescription = errorDescription
    }
}

public struct EmptyTrashResult: Sendable {
    public let itemResults: [EmptyTrashItemResult]
    public let confirmationAccepted: Bool
    public let availableBytesBefore: Int64?
    public let availableBytesAfter: Int64?
    public let inventoryWasPartial: Bool

    public var deletedBytesUpperBound: Int64 {
        itemResults.reduce(0) { $0 + ($1.status == .deleted ? $1.allocatedBytesUpperBound : 0) }
    }
    public var measuredAvailableBytesGain: Int64? {
        guard let before = availableBytesBefore, let after = availableBytesAfter else { return nil }
        return max(0, after - before)
    }
    public var wasCancelled: Bool { itemResults.contains { $0.status == .cancelled } }

    public init(itemResults: [EmptyTrashItemResult], confirmationAccepted: Bool, availableBytesBefore: Int64?, availableBytesAfter: Int64?, inventoryWasPartial: Bool = false) {
        self.itemResults = itemResults
        self.confirmationAccepted = confirmationAccepted
        self.availableBytesBefore = availableBytesBefore
        self.availableBytesAfter = availableBytesAfter
        self.inventoryWasPartial = inventoryWasPartial
    }
}

public actor TrashService {
    public init() {}

    /// Captures the device/inode identity that must still match immediately before mutation.
    public func preflight(
        _ items: [FileSystemItem],
        authorization: TrashAuthorization = .userSelection
    ) -> [TrashPreflightResult] {
        SelectionNormalizer.normalize(items).map { item in
            do {
                try validateTrashable(item, authorization: authorization)
                let liveIdentity = try identity(at: item.url)
                if let indexed = item.indexedIdentity {
                    let liveValues = try URL(fileURLWithPath: item.url.path).resourceValues(forKeys: [.volumeUUIDStringKey, .creationDateKey])
                    if let uuid = item.indexedVolumeUUID {
                        let liveUUID = liveValues.volumeUUIDString
                        guard uuid == liveUUID, indexed.inode == liveIdentity.inode, indexed.fileType == liveIdentity.fileType else { throw TrashError.identityChanged(item.url.path) }
                    } else if indexed != liveIdentity { throw TrashError.identityChanged(item.url.path) }
                    if let created = item.creationDate, liveValues.creationDate != created { throw TrashError.identityChanged(item.url.path) }
                }
                return TrashPreflightResult(
                    item: item, identity: liveIdentity,
                    authorization: authorization, errorDescription: nil
                )
            } catch {
                return TrashPreflightResult(
                    item: item, identity: nil, authorization: authorization,
                    errorDescription: error.localizedDescription
                )
            }
        }
    }

    /// Detailed, partial-success API. Every input receives a terminal result, including
    /// selections covered by an already selected parent and duplicate paths.
    public func trashWithResults(_ items: [FileSystemItem]) async -> [TrashOperationResult] {
        let prepared = preflight(items)
        let preparedResults = await trashWithResults(prepared)
        let normalizedPaths = Set(prepared.map { $0.item.url.standardizedFileURL.path })
        let resultsByPath = Dictionary(uniqueKeysWithValues: preparedResults.map {
            ($0.originalURL.standardizedFileURL.path, $0)
        })
        var firstOccurrence: Set<String> = []
        return items.map { item in
            let path = item.url.standardizedFileURL.path
            if firstOccurrence.contains(path) {
                return TrashOperationResult(originalURL: item.url, status: .skippedDuplicate,
                    allocatedBytesUpperBound: item.allocatedSize, errorDescription: "Chemin sélectionné plusieurs fois.")
            }
            firstOccurrence.insert(path)
            if !normalizedPaths.contains(path) {
                return TrashOperationResult(originalURL: item.url, status: .skippedCoveredByParent,
                    allocatedBytesUpperBound: item.allocatedSize, errorDescription: "Déjà couvert par un dossier parent sélectionné.")
            }
            return resultsByPath[path] ?? TrashOperationResult(
                originalURL: item.url, status: .cancelled, allocatedBytesUpperBound: item.allocatedSize
            )
        }
    }

    /// Executes identities captured before a UI confirmation. The captured identity is the
    /// authority: the live stat is used only to compare and is never promoted to a new reference.
    public func trashWithResults(_ prepared: [TrashPreflightResult]) async -> [TrashOperationResult] {
        let normalized = SelectionNormalizer.normalize(prepared.map(\.item))
        let normalizedPaths = Set(normalized.map { $0.url.standardizedFileURL.path })
        var firstOccurrence: Set<String> = []

        return prepared.map { value in
            let item = value.item
            let path = item.url.standardizedFileURL.path
            if firstOccurrence.contains(path) {
                return TrashOperationResult(
                    originalURL: item.url, expectedIdentity: value.identity, status: .skippedDuplicate,
                    allocatedBytesUpperBound: item.allocatedSize, errorDescription: "Chemin préparé plusieurs fois."
                )
            }
            firstOccurrence.insert(path)
            if !normalizedPaths.contains(path) {
                return TrashOperationResult(
                    originalURL: item.url, expectedIdentity: value.identity, status: .skippedCoveredByParent,
                    allocatedBytesUpperBound: item.allocatedSize,
                    errorDescription: "Déjà couvert par un dossier parent préparé."
                )
            }
            if Task.isCancelled {
                return TrashOperationResult(
                    originalURL: item.url, expectedIdentity: value.identity, status: .cancelled,
                    allocatedBytesUpperBound: item.allocatedSize
                )
            }

            guard value.isReady, let expectedIdentity = value.identity else {
                return TrashOperationResult(
                    originalURL: item.url, expectedIdentity: value.identity, status: .failed,
                    allocatedBytesUpperBound: item.allocatedSize,
                    errorDescription: value.errorDescription ?? "Préflight incomplet."
                )
            }

            do {
                try validateTrashable(item, authorization: value.authorization)
                guard try identity(at: item.url) == expectedIdentity else { throw TrashError.identityChanged(item.url.path) }
                try OperationJournal.append(operation: "corbeille", path: item.url.path, status: "préparé")
                var resultURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultURL)
                try? OperationJournal.append(operation: "corbeille", path: item.url.path, status: "corbeille")
                return TrashOperationResult(
                    originalURL: item.url, resultingURL: resultURL as URL?, expectedIdentity: expectedIdentity,
                    status: .trashed, allocatedBytesUpperBound: item.allocatedSize
                )
            } catch {
                try? OperationJournal.append(operation: "corbeille", path: item.url.path, status: "échec", message: error.localizedDescription)
                return TrashOperationResult(
                    originalURL: item.url, expectedIdentity: expectedIdentity, status: .failed,
                    allocatedBytesUpperBound: item.allocatedSize, errorDescription: error.localizedDescription
                )
            }
        }
    }

    /// Compatibility API used by the existing UI.
    public func trash(_ items: [FileSystemItem]) async throws -> [URL] {
        let results = await trashWithResults(items)
        if let failure = results.first(where: { $0.status == .failed }) {
            throw TrashError.operationFailed(path: failure.originalURL.path, message: failure.errorDescription ?? "Erreur inconnue")
        }
        if Task.isCancelled { throw CancellationError() }
        return results.compactMap { $0.status == .trashed ? $0.resultingURL : nil }
    }

    /// Inventories direct children of the current user's trash directories. Trash roots
    /// themselves are never returned and therefore cannot be removed by `emptyTrash`.
    public func inventoryTrash(volumes: [StorageVolume] = StorageService.mountedVolumes()) async -> TrashInventory {
        await RecursiveReadBudget.shared.acquire()
        defer { Task { await RecursiveReadBudget.shared.release() } }
        var items: [TrashInventoryItem] = []
        var issues: [TrashInventoryIssue] = []
        var wasCancelled = false
        var seenRoots: Set<FileIdentity> = []

        for root in approvedTrashRoots(volumes: volumes) {
            if Task.isCancelled { wasCancelled = true; break }
            do {
                try validateTrashRoot(root)
                guard seenRoots.insert(try identity(at: root)).inserted else { continue }
                let children = try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
                )
                for child in children {
                    if Task.isCancelled { wasCancelled = true; break }
                    do {
                        let childIdentity = try identity(at: child)
                        let measurement = measureTrashItem(child)
                        issues += measurement.issues
                        items.append(TrashInventoryItem(
                            url: child, trashRoot: root, identity: childIdentity,
                            allocatedBytesUpperBound: measurement.bytes,
                            isDirectory: childIdentity.fileType == UInt16(S_IFDIR),
                            sizeIsComplete: measurement.issues.isEmpty && !Task.isCancelled
                        ))
                    } catch {
                        issues.append(.from(error, path: child.path))
                    }
                }
            } catch TrashError.missingItem(_) {
                continue
            } catch {
                issues.append(.from(error, path: root.path))
            }
        }

        return TrashInventory(
            items: items.sorted { $0.allocatedBytesUpperBound == $1.allocatedBytesUpperBound
                ? $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                : $0.allocatedBytesUpperBound > $1.allocatedBytesUpperBound },
            issues: issues, wasCancelled: wasCancelled || Task.isCancelled
        )
    }

    /// Permanently deletes inventoried trash children. Explicit authorization is
    /// bound to the reviewed inventory so a stale confirmation cannot authorize another one.
    public func emptyTrash(
        _ inventory: TrashInventory, authorization: TrashEmptyAuthorization,
        volumes: [StorageVolume] = StorageService.mountedVolumes()
    ) async -> EmptyTrashResult {
        let accepted = authorization.inventoryID == inventory.id
        let measuredVolumeIDs = Set(inventory.items.compactMap { item in
            volumes.filter { volume in
                let root = volume.url.standardizedFileURL.path
                return item.trashRoot.path == root || item.trashRoot.path.hasPrefix(root == "/" ? "/" : root + "/")
            }.max(by: { $0.url.path.count < $1.url.path.count })?.id
        })
        let before = importantAvailableBytes(for: StorageService.mountedVolumes(), restrictedTo: measuredVolumeIDs)
        guard accepted else {
            return EmptyTrashResult(itemResults: [], confirmationAccepted: false,
                availableBytesBefore: before, availableBytesAfter: before)
        }

        let liveRoots = Set(approvedTrashRoots(volumes: volumes).filter { trashRootIsSafe($0) }.map { $0.standardizedFileURL.path })
        var results: [EmptyTrashItemResult] = []
        for item in inventory.items {
            if Task.isCancelled {
                results.append(EmptyTrashItemResult(url: item.url, status: .cancelled,
                    allocatedBytesUpperBound: item.allocatedBytesUpperBound, errorDescription: "Opération annulée."))
                continue
            }

            let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
            guard liveRoots.contains(parent), parent == item.trashRoot.standardizedFileURL.path else {
                results.append(EmptyTrashItemResult(url: item.url, status: .failed,
                    allocatedBytesUpperBound: item.allocatedBytesUpperBound,
                    errorDescription: "La cible n’est plus un enfant direct d’une Corbeille approuvée."))
                continue
            }

            do {
                guard try identity(at: item.url) == item.identity else {
                    results.append(EmptyTrashItemResult(url: item.url, status: .identityChanged,
                        allocatedBytesUpperBound: item.allocatedBytesUpperBound,
                        errorDescription: "L’élément a changé depuis l’inventaire."))
                    continue
                }
                try OperationJournal.append(operation: "vidage corbeille", path: item.url.path, status: "préparé")
                try FileManager.default.removeItem(at: item.url)
                try? OperationJournal.append(operation: "vidage corbeille", path: item.url.path, status: "supprimé")
                results.append(EmptyTrashItemResult(url: item.url, status: .deleted,
                    allocatedBytesUpperBound: item.allocatedBytesUpperBound))
            } catch {
                results.append(EmptyTrashItemResult(url: item.url, status: .failed,
                    allocatedBytesUpperBound: item.allocatedBytesUpperBound, errorDescription: error.localizedDescription))
            }
        }

        return EmptyTrashResult(
            itemResults: results, confirmationAccepted: true, availableBytesBefore: before,
            availableBytesAfter: importantAvailableBytes(
                for: StorageService.mountedVolumes(), restrictedTo: measuredVolumeIDs
            ), inventoryWasPartial: inventory.isPartial
        )
    }

    private func validateTrashable(_ item: FileSystemItem, authorization: TrashAuthorization) throws {
        let path = item.url.standardizedFileURL.path
        guard !DeletionSafetyPolicy.isCloudPath(path), !DeletionSafetyPolicy.isManagedGamePath(path) else { throw TrashError.protectedItem(path) }
        var ancestor = item.url.standardizedFileURL
        while ancestor.path != "/" {
            let values = try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey])
            if values.isSymbolicLink == true || values.isUbiquitousItem == true { throw TrashError.protectedItem(path) }
            ancestor.deleteLastPathComponent()
        }
        switch authorization {
        case .userSelection:
            guard item.isTrashable,
                  !DeletionSafetyPolicy.isProtectedForUserSelection(item.url, isDirectory: item.isDirectory) else {
                throw TrashError.protectedItem(path)
            }
        case .manualApplicationData:
            guard !item.isSymbolicLink, DeletionSafetyPolicy.requiresApplicationDataReview(item.url) else {
                throw TrashError.protectedItem(path)
            }
        case .verifiedApplicationAssociation(let bundleIdentifier):
            guard DeletionSafetyPolicy.allowsVerifiedApplicationAssociation(
                item.url, bundleIdentifier: bundleIdentifier, isDirectory: item.isDirectory
            ) else { throw TrashError.protectedItem(path) }
        }
        guard !isProtectedSystemPath(path) else { throw TrashError.protectedItem(path) }
        guard FileManager.default.fileExists(atPath: path) || isSymbolicLink(at: item.url) else { throw TrashError.missingItem(path) }
        guard try ownerUID(at: item.url) != 0 else {
            throw TrashError.operationFailed(path: path, message: "Cet élément appartient à un administrateur. Examinez-le dans le Finder, qui peut demander l’authentification du système.")
        }
    }

    private func isProtectedSystemPath(_ path: String) -> Bool {
        let exact = ["/", "/Applications", "/Users", "/Volumes"]
        let protectedTrees = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/dev", "/etc", "/var"]
        return exact.contains(path) || protectedTrees.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func identity(at url: URL) throws -> FileIdentity {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &information)
        }
        guard result == 0 else {
            if errno == ENOENT { throw TrashError.missingItem(url.path) }
            if errno == EACCES || errno == EPERM { throw TrashError.accessDenied(url.path) }
            throw TrashError.operationFailed(path: url.path, message: String(cString: strerror(errno)))
        }
        return FileIdentity(deviceID: FileIdentity.deviceID(fromRawValue: information.st_dev), inode: UInt64(information.st_ino),
            fileType: UInt16(information.st_mode & S_IFMT))
    }

    private func ownerUID(at url: URL) throws -> uid_t {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &information)
        }
        guard result == 0 else {
            if errno == ENOENT { throw TrashError.missingItem(url.path) }
            throw TrashError.operationFailed(path: url.path, message: String(cString: strerror(errno)))
        }
        return information.st_uid
    }

    private func approvedTrashRoots(volumes: [StorageVolume]) -> [URL] {
        var roots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)]
        let uid = getuid()
        for volume in volumes where volume.isLocal {
            roots.append(volume.url.appendingPathComponent(".Trashes", isDirectory: true)
                .appendingPathComponent(String(uid), isDirectory: true))
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func trashRootIsSafe(_ root: URL) -> Bool {
        (try? validateTrashRoot(root)) != nil
    }

    private func validateTrashRoot(_ root: URL) throws {
        guard try identity(at: root).fileType == UInt16(S_IFDIR), try ownerUID(at: root) == getuid(),
              root.deletingLastPathComponent().lastPathComponent != ".Trashes" || !isSymbolicLink(at: root.deletingLastPathComponent()) else {
            throw TrashError.protectedItem(root.path)
        }
    }

    private func measureTrashItem(_ root: URL) -> (bytes: Int64, issues: [TrashInventoryIssue]) {
        do { return try measureAccessibleTrashItem(root) }
        catch { return (0, [.from(error, path: root.path)]) }
    }

    private func measureAccessibleTrashItem(_ root: URL) throws -> (bytes: Int64, issues: [TrashInventoryIssue]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileAllocatedSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        if rootValues.isSymbolicLink == true || rootValues.isDirectory != true { return (try measuredAllocation(rootValues, at: root), []) }

        var total = try measuredAllocation(rootValues, at: root)
        var issues: [TrashInventoryIssue] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { url, error in issues.append(.from(error, path: url.path)); return true }
        ) else { return (total, [TrashInventoryIssue(path: root.path, message: "Le contenu de ce dossier n’a pas pu être mesuré.")]) }
        for case let url as URL in enumerator {
            if Task.isCancelled { issues.append(TrashInventoryIssue(path: root.path, message: "Calcul annulé.")); break }
            // Foundation's enumerator does not follow links. Never call the
            // directory-only skip operation on a link returned between siblings.
            do { let values = try url.resourceValues(forKeys: keys); total += try measuredAllocation(values, at: url) }
            catch { issues.append(.from(error, path: url.path)) }
        }
        return (total, issues)
    }

    private func measuredAllocation(_ values: URLResourceValues, at url: URL) throws -> Int64 {
        if values.isSymbolicLink != true, let bytes = values.fileAllocatedSize { return Int64(bytes) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == EACCES || errno == EPERM { throw TrashError.accessDenied(url.path) }
            throw TrashError.operationFailed(path: url.path, message: String(cString: strerror(errno)))
        }
        return Int64(info.st_blocks) * 512
    }

    private func importantAvailableBytes(for volumes: [StorageVolume], restrictedTo ids: Set<String>) -> Int64? {
        var measured: [String: Int64] = [:]
        for volume in volumes where ids.contains(volume.id) { measured[volume.id] = volume.available }
        guard !measured.isEmpty else { return nil }
        return measured.values.reduce(0, +)
    }
}
