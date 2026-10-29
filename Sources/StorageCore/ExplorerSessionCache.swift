import Foundation

public struct ExplorerViewSnapshot: Sendable {
    public let items: [FileSystemItem]
    public let largest: [FileSystemItem]
    public let smallest: [FileSystemItem]
    public let names: [FileSystemItem]
    public let types: [FileSystemItem]
    public let dates: [FileSystemItem]
    public let paths: [FileSystemItem]
    public var frame: FolderBubbleFrame?
    public var layout: String
    public var selection: Set<String>
    public var scroll: Double
    public let cost: Int
    public init(items: [FileSystemItem], frame: FolderBubbleFrame?, layout: String, selection: Set<String> = [], scroll: Double = .nan) {
        self.items = items; self.frame = frame; self.layout = layout; self.selection = selection; self.scroll = scroll
        largest = items.sorted { $0.allocatedSize == $1.allocatedSize ? $0.id < $1.id : $0.allocatedSize > $1.allocatedSize }
        smallest = items.sorted { $0.allocatedSize == $1.allocatedSize ? $0.id < $1.id : $0.allocatedSize < $1.allocatedSize }
        names = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        types = items.sorted { $0.category == $1.category ? $0.id < $1.id : $0.category.rawValue < $1.category.rawValue }
        dates = items.sorted { ($0.modificationDate ?? .distantPast) == ($1.modificationDate ?? .distantPast) ? $0.id < $1.id : ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        paths = items.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        cost = 512 + items.reduce(0) { $0 + MemoryLayout<FileSystemItem>.stride * 7 + ($1.url.path.utf16.count + $1.name.utf16.count) * 2 }
    }
}

public struct ExplorerSessionCache: Sendable {
    public static let capacity = 64 * 1024 * 1024
    private var entries: [String: (value: ExplorerViewSnapshot, used: UInt64)] = [:]
    private var clock: UInt64 = 0
    public private(set) var bytes = 0
    public var count: Int { entries.count }
    public init() {}
    public mutating func get(_ key: String) -> ExplorerViewSnapshot? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.used = clock; entries[key] = entry; return entry.value
    }
    public mutating func put(_ key: String, _ value: ExplorerViewSnapshot) {
        if let old = entries.removeValue(forKey: key) { bytes -= old.value.cost }
        guard value.cost <= Self.capacity else { return }
        clock &+= 1; entries[key] = (value, clock); bytes += value.cost
        while bytes > Self.capacity || entries.count > 32 {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
            bytes -= oldest.value.value.cost; entries.removeValue(forKey: oldest.key)
        }
    }
    public mutating func clear() { entries.removeAll(); bytes = 0 }
}
