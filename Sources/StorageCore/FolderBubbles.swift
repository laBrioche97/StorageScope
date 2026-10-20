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
    public let parentBytes: Int64
    public init(path: String, name: String, bytes: Int64, circle: PackedCircle, depth: Int, isAggregate: Bool = false, skipCount: Int = 0, parentBytes: Int64 = 0) {
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

extension DirectoryIndexStore {
    public func bubbleFrame(forPath path: String, partial: Bool) throws -> FolderBubbleFrame {
        var output: [FolderBubble] = []
        var budget = 200
        let rootSummary = try summary(forPath: path)
        let total = rootSummary?.allocatedSize
        try add(path, bytes: total ?? 0, x: 0, y: 0, radius: 1, depth: 0)
        let childTotal = try bubbleChildTotals(of: path).bytes
        return FolderBubbleFrame(folders: output, totalBytes: total, directFileBytes: total.map { max(0, $0 - childTotal) }, isPartial: partial, updatedAt: try metadata().updatedAt)

        func add(_ parent: String, bytes: Int64, x: Double, y: Double, radius: Double, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 3, budget > 0 else { return }
            let totals = try bubbleChildTotals(of: parent)
            let take = min(32, budget, totals.count)
            guard take > 0 else { return }
            let grouped = totals.count > take
            let children = try children(of: parent, limit: grouped ? take - 1 : take).filter { $0.allocatedSize > 0 }
            var visible = children.map { (path: $0.path, name: URL(fileURLWithPath: $0.path).lastPathComponent, bytes: $0.allocatedSize, aggregate: false) }
            if grouped { visible.append((parent, "Autres dossiers (\(totals.count - children.count))", max(0, totals.bytes - children.reduce(0) { $0 + $1.allocatedSize }), true)) }
            budget -= visible.count
            let circles = CirclePacking.pack(visible.map { Double($0.bytes) })
            let fraction = bytes > 0 ? min(1, Double(totals.bytes) / Double(bytes)) : 1
            let scale = radius * 0.90 * sqrt(fraction)
            let siblings = zip(visible, circles).map { item, circle in
                FolderBubble(path: item.path, name: item.name, bytes: item.bytes, circle: PackedCircle(x: x + circle.x * scale, y: y + circle.y * scale, radius: circle.radius * scale), depth: depth, isAggregate: item.aggregate, skipCount: children.count, parentBytes: bytes)
            }
            output.append(contentsOf: siblings)
            for node in siblings where !node.isAggregate {
                try add(node.path, bytes: node.bytes, x: node.circle.x, y: node.circle.y, radius: node.circle.radius, depth: depth + 1)
            }
        }
    }
}
