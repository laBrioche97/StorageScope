import Darwin
import Foundation

/// One namespace for the scan, browser and journal. APFS firmlinks belong to the
/// startup volume group; /System/Volumes and other mounted volumes do not.
public struct ScanPathPolicy: Sendable {
    public let root: URL
    private let rootPath: String
    private let devices: Set<UInt64>
    private let ownedPaths: [String]
    private let volumeUUIDs: [UInt64: String]
    public init(root: URL) {
        self.root = root.standardized
        self.rootPath = root.standardized.path
        var devices = Set(Self.identity(root).map { [$0.deviceID] } ?? [])
        if root.path == "/", let data = Self.identity(URL(fileURLWithPath: "/System/Volumes/Data")) {
            devices.insert(data.deviceID)
        }
        self.devices = devices
        var uuids: [UInt64: String] = [:]
        for url in [root, URL(fileURLWithPath: "/System/Volumes/Data")] {
            if let identity = Self.identity(url), devices.contains(identity.deviceID), let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString { uuids[identity.deviceID] = uuid }
        }
        self.volumeUUIDs = uuids
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.ownedPaths = [home + "/Library/Application Support/StorageScope", home + "/Library/Caches/StorageScope"]
    }

    public func excludes(_ url: URL) -> Bool {
        // Callers enumerate canonical roots or normalize journal paths once.
        let path = url.path
        guard rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/") else { return true }
        if rootPath == "/", ["/Volumes", "/System/Volumes", "/dev"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        // Only our own changing metadata is excluded, never another application's files.
        return ownedPaths.contains {
            path == $0 || path.hasPrefix($0 + "/")
        }
    }

    public func volumeUUID(for identity: FileIdentity?) -> String? { identity.flatMap { volumeUUIDs[$0.deviceID] } }
    public func acceptsDevice(_ identity: FileIdentity) -> Bool { devices.contains(identity.deviceID) }
    /// Foundation's resolvingSymlinksInPath can shorten /private again. Use the
    /// kernel's physical path only for containment checks and root resolution.
    public static func physicalURL(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url.standardized }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    public static func identity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(deviceID: FileIdentity.deviceID(fromRawValue: info.st_dev), inode: UInt64(info.st_ino), fileType: UInt16(info.st_mode & S_IFMT))
    }

    public func validateDirectory(_ input: URL) throws {
        let url = input.standardized
        guard !excludes(url), let identity = Self.identity(url), identity.fileType == UInt16(S_IFDIR), acceptsDevice(identity) else {
            throw DirectoryIndexError.outsideRoot(path: url.path, root: root.path)
        }
        var current = url.standardized
        while current.path != root.path {
            guard let identity = Self.identity(current), identity.fileType != UInt16(S_IFLNK) else { throw DirectoryIndexError.unavailable }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { throw DirectoryIndexError.unavailable }
            current = parent
        }
    }
}
