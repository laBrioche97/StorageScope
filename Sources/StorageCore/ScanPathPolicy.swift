import Darwin
import Foundation

/// One namespace for the scan, browser and journal. APFS firmlinks belong to the
/// startup volume group; /System/Volumes and other mounted volumes do not.
public struct ScanPathPolicy: Sendable {
    public let root: URL
    private let devices: Set<UInt64>
    private let ownedPaths: [String]
    public init(root: URL) {
        self.root = root.standardizedFileURL
        var devices = Set(Self.identity(root).map { [$0.deviceID] } ?? [])
        if root.path == "/", let data = Self.identity(URL(fileURLWithPath: "/System/Volumes/Data")) {
            devices.insert(data.deviceID)
        }
        self.devices = devices
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.ownedPaths = [home + "/Library/Application Support/StorageScope", home + "/Library/Caches/StorageScope"]
    }

    public func excludes(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard root.path == "/" || path == root.path || path.hasPrefix(root.path + "/") else { return true }
        if root.path == "/", ["/Volumes", "/System/Volumes", "/dev"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        // Only our own changing metadata is excluded, never another application's files.
        return ownedPaths.contains {
            path == $0 || path.hasPrefix($0 + "/")
        }
    }

    public func acceptsDevice(_ identity: FileIdentity) -> Bool { devices.contains(identity.deviceID) }
    public static func identity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(deviceID: FileIdentity.deviceID(fromRawValue: info.st_dev), inode: UInt64(info.st_ino), fileType: UInt16(info.st_mode & S_IFMT))
    }

    public func validateDirectory(_ url: URL) throws {
        guard !excludes(url), let identity = Self.identity(url), identity.fileType == UInt16(S_IFDIR), acceptsDevice(identity) else {
            throw DirectoryIndexError.outsideRoot(path: url.path, root: root.path)
        }
        var current = url.standardizedFileURL
        while current.path != root.path {
            guard let identity = Self.identity(current), identity.fileType != UInt16(S_IFLNK) else { throw DirectoryIndexError.unavailable }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { throw DirectoryIndexError.unavailable }
            current = parent
        }
    }
}
