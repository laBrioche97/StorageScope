import Foundation

public struct PackedCircle: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let radius: Double
    public init(x: Double, y: Double, radius: Double) { self.x = x; self.y = y; self.radius = radius }
}

public enum CirclePacking {
    /// Deterministic placement with a shared scale; sibling areas track their weights.
    public static func pack(_ weights: [Double]) -> [PackedCircle] {
        guard let maximum = weights.max(), maximum > 0, maximum.isFinite else { return [] }
        var placed: [PackedCircle] = []
        for weight in weights {
            let r = sqrt(max(0, weight) / maximum)
            if placed.isEmpty { placed.append(PackedCircle(x: 0, y: 0, radius: r)); continue }
            var best: PackedCircle?
            var score = Double.greatestFiniteMagnitude
            for anchor in placed {
                for angle in 0..<48 {
                    let theta = Double(angle) * .pi / 24
                    let candidate = PackedCircle(x: anchor.x + (anchor.radius + r + 0.002) * cos(theta), y: anchor.y + (anchor.radius + r + 0.002) * sin(theta), radius: r)
                    if placed.contains(where: { pow($0.x - candidate.x, 2) + pow($0.y - candidate.y, 2) < pow($0.radius + r + 0.001, 2) }) { continue }
                    let candidateScore = hypot(candidate.x, candidate.y) + r
                    if candidateScore < score { best = candidate; score = candidateScore }
                }
            }
            placed.append(best ?? PackedCircle(x: (placed.map { $0.x + $0.radius }.max() ?? 0) + r + 0.002, y: 0, radius: r))
        }
        let cx = ((placed.map { $0.x - $0.radius }.min() ?? 0) + (placed.map { $0.x + $0.radius }.max() ?? 0)) / 2
        let cy = ((placed.map { $0.y - $0.radius }.min() ?? 0) + (placed.map { $0.y + $0.radius }.max() ?? 0)) / 2
        let enclosing = placed.map { hypot($0.x - cx, $0.y - cy) + $0.radius }.max() ?? 1
        return placed.map { PackedCircle(x: ($0.x - cx) / enclosing, y: ($0.y - cy) / enclosing, radius: $0.radius / enclosing) }
    }
}

public struct FolderBubble: Identifiable, Sendable {
    public var id: String { path + (isAggregate ? "#others" : "") }
    public let path: String
    public let name: String
    public let bytes: Int64
    public let circle: PackedCircle
    public let depth: Int
    public let isAggregate: Bool
    public let skipCount: Int
    public let isDirectory: Bool
    public let parentBytes: Int64
    public init(path: String, name: String, bytes: Int64, circle: PackedCircle, depth: Int, isAggregate: Bool = false, skipCount: Int = 0, parentBytes: Int64 = 0, isDirectory: Bool = true) {
        self.isDirectory = isDirectory
        self.path = path; self.name = name; self.bytes = bytes; self.circle = circle
        self.depth = depth; self.isAggregate = isAggregate; self.skipCount = skipCount; self.parentBytes = parentBytes
    }
}

public struct FolderBubbleFrame: Sendable {
    public let folders: [FolderBubble]
    public let totalBytes: Int64?
    public let directFileBytes: Int64?
    public let isPartial: Bool
    public let updatedAt: Date?
    public init(folders: [FolderBubble], totalBytes: Int64?, directFileBytes: Int64?, isPartial: Bool, updatedAt: Date?) {
        self.folders = folders; self.totalBytes = totalBytes; self.directFileBytes = directFileBytes
        self.isPartial = isPartial; self.updatedAt = updatedAt
    }
}

public enum ExplorerBubbleLayout {
    public static func frame(path: String, items: [FileSystemItem], total: Int64?, partial: Bool, maximum: Int = 24, updatedAt: Date? = nil, availableDiameter: Double = .infinity) throws -> FolderBubbleFrame {
        try Task.checkCancellation()
        let known = items.filter { $0.hasKnownSize && $0.allocatedSize > 0 && !$0.isSymbolicLink }.sorted {
            $0.allocatedSize == $1.allocatedSize ? $0.id < $1.id : $0.allocatedSize > $1.allocatedSize
        }
        var limit = min(24, max(2, maximum))
        var visible: [(item: FileSystemItem, aggregate: Bool)] = []
        var circles: [PackedCircle] = []
        var take = 0
        repeat {
        try Task.checkCancellation()
        take = known.count > limit ? limit - 1 : known.count
        visible = Array(known.prefix(take)).map { (item: $0, aggregate: false) }
        if known.count > take {
            let bytes = known.dropFirst(take).reduce(Int64(0)) { SaturatingArithmetic.addNonnegative($0, $1.allocatedSize) }
            let other = FileSystemItem(url: URL(fileURLWithPath: path), name: "Autres éléments (\(known.count - take))", logicalSize: bytes, allocatedSize: bytes, isDirectory: true, sizeIsKnown: true)
            visible.append((other, true))
        }
        circles = CirclePacking.pack(visible.map { Double($0.item.allocatedSize) })
        if limit <= 2 || circles.allSatisfy({ $0.radius * availableDiameter * 0.97 >= 80 }) { break }
        limit -= 1
        } while true
        let nodes = zip(visible, circles).map { entry, circle in
            FolderBubble(path: entry.item.id, name: entry.item.name, bytes: entry.item.allocatedSize,
                         circle: PackedCircle(x: circle.x * 0.97, y: circle.y * 0.97, radius: circle.radius * 0.97), depth: 0,
                         isAggregate: entry.aggregate, skipCount: take, parentBytes: total ?? 0, isDirectory: entry.item.isDirectory)
        }
        let direct = known.filter { !$0.isDirectory }.reduce(Int64(0)) { SaturatingArithmetic.addNonnegative($0, $1.allocatedSize) }
        return FolderBubbleFrame(folders: nodes, totalBytes: total, directFileBytes: direct,
                                 isPartial: partial || items.contains { !$0.hasKnownSize }, updatedAt: updatedAt)
    }
}

extension DirectoryIndexStore {
    public func bubbleFrame(forPath path: String, partial: Bool, items: [FileSystemItem]? = nil, maximumVisible: Int = 24, availableDiameter: Double = .infinity) throws -> FolderBubbleFrame {
        let rootSummary = try summary(forPath: path)
        let entries: [FileSystemItem]
        if let items { entries = items }
        else {
            entries = try children(of: path, limit: 100_000).map {
                FileSystemItem(url: URL(fileURLWithPath: $0.path), logicalSize: $0.logicalSize,
                               allocatedSize: $0.allocatedSize, isDirectory: true, sizeIsKnown: true)
            }
        }
        let frame = try ExplorerBubbleLayout.frame(path: path, items: entries, total: rootSummary?.allocatedSize,
                                                   partial: partial, maximum: maximumVisible, updatedAt: try metadata().updatedAt, availableDiameter: availableDiameter)
        // Without a directory listing, only the index can estimate direct-file bytes.
        guard items == nil else { return frame }
        let childBytes = try bubbleChildTotals(of: path).bytes
        return FolderBubbleFrame(folders: frame.folders, totalBytes: frame.totalBytes,
                                 directFileBytes: frame.totalBytes.map { max(0, $0 - childBytes) }, isPartial: frame.isPartial, updatedAt: frame.updatedAt)
    }
}
