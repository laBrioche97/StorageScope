import Foundation

public struct StorageVolume: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let capacity: Int64
    public let available: Int64
    public let isLocal: Bool
    public let isInternal: Bool

    public var used: Int64 { max(0, capacity - available) }

    public init(
        id: String,
        url: URL,
        name: String,
        capacity: Int64,
        available: Int64,
        isLocal: Bool,
        isInternal: Bool
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.capacity = capacity
        self.available = available
        self.isLocal = isLocal
        self.isInternal = isInternal
    }
}

public enum StorageService {
    public static func mountedVolumes() -> [StorageVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIdentifierKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [URL(fileURLWithPath: "/")]
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false else { return nil }
            let path = url.standardizedFileURL.path
            let stableID = values.volumeIdentifier.map { String(describing: $0) } ?? path
            return StorageVolume(
                id: stableID,
                url: url,
                name: values.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent),
                capacity: Int64(values.volumeTotalCapacity ?? 0),
                available: values.volumeAvailableCapacityForImportantUsage ?? 0,
                isLocal: values.volumeIsLocal ?? true,
                isInternal: values.volumeIsInternal ?? (url.path == "/")
            )
        }.sorted { lhs, rhs in
            if lhs.url.path == "/" { return true }
            if rhs.url.path == "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
