import Foundation

/// A platform-neutral rectangle used by the treemap engine. Coordinates are
/// expressed in the same unit as the bounds supplied to ``TreemapLayoutEngine``.
public struct TreemapRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let unit = TreemapRect(x: 0, y: 0, width: 1, height: 1)

    public var area: Double { max(0, width) * max(0, height) }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public struct TreemapValue: Hashable, Sendable {
    public let id: String
    public let weight: Int64

    public init(id: String, weight: Int64) {
        self.id = id
        self.weight = max(0, weight)
    }
}

public struct TreemapTile: Identifiable, Hashable, Sendable {
    public let id: String
    public let weight: Int64
    public let rect: TreemapRect

    public init(id: String, weight: Int64, rect: TreemapRect) {
        self.id = id
        self.weight = weight
        self.rect = rect
    }
}

public struct TreemapPartition: Hashable, Sendable {
    public let visible: [TreemapValue]
    public let grouped: [TreemapValue]

    public init(visible: [TreemapValue], grouped: [TreemapValue]) {
        self.visible = visible
        self.grouped = grouped
    }
}

/// Deterministic squarified-treemap layout.
///
/// Values are ordered by descending weight, then by their stable identifier.
/// Positive values occupy an area exactly proportional to their weight. Zero
/// values receive an empty rectangle when mixed with positive values. If every
/// value is zero, the available area is shared equally so an unfinished scan
/// remains navigable instead of producing NaN or invisible content.
public enum TreemapLayoutEngine {
    private struct Entry: Sendable {
        let value: TreemapValue
        let area: Double
    }

    public static func partition(
        _ values: [TreemapValue],
        maximumVisibleItems: Int = 60,
        minimumVisibleFraction: Double = 0.003
    ) -> TreemapPartition {
        let sorted = sortedValues(values)
        guard !sorted.isEmpty else { return TreemapPartition(visible: [], grouped: []) }

        let maximum = max(1, maximumVisibleItems)
        let minimumFraction = max(0, minimumVisibleFraction)
        let total = sorted.reduce(0.0) { $0 + Double($1.weight) }

        // Keep unfinished scans bounded as well. layout() shares the surface
        // equally between the visible zero-sized entries and the group tile.
        guard total > 0 else {
            return TreemapPartition(
                visible: Array(sorted.prefix(maximum)),
                grouped: Array(sorted.dropFirst(maximum))
            )
        }

        var visible: [TreemapValue] = []
        var grouped: [TreemapValue] = []
        visible.reserveCapacity(min(maximum, sorted.count))

        for value in sorted {
            let fraction = Double(value.weight) / Double(total)
            if visible.count < maximum, value.weight > 0, fraction >= minimumFraction {
                visible.append(value)
            } else {
                grouped.append(value)
            }
        }

        // Always preserve at least one real tile. This also makes a directory
        // containing only sub-threshold items useful before opening the group.
        if visible.isEmpty, let first = grouped.first {
            visible.append(first)
            grouped.removeFirst()
        }
        return TreemapPartition(visible: visible, grouped: grouped)
    }

    public static func layout(
        _ values: [TreemapValue],
        in bounds: TreemapRect = .unit
    ) -> [TreemapTile] {
        let sorted = sortedValues(values)
        guard !sorted.isEmpty else { return [] }

        let safeBounds = sanitized(bounds)
        guard safeBounds.area > 0 else {
            let empty = TreemapRect(x: safeBounds.x, y: safeBounds.y, width: 0, height: 0)
            return sorted.map { TreemapTile(id: $0.id, weight: $0.weight, rect: empty) }
        }

        let positiveTotal = sorted.reduce(0.0) { $0 + Double($1.weight) }
        let allZero = positiveTotal == 0
        let effectiveTotal = allZero ? Double(sorted.count) : positiveTotal

        let entries = sorted.compactMap { value -> Entry? in
            let effectiveWeight = allZero ? 1.0 : Double(value.weight)
            guard effectiveWeight > 0 else { return nil }
            return Entry(value: value, area: safeBounds.area * effectiveWeight / effectiveTotal)
        }

        var laidOut: [String: TreemapRect] = [:]
        laidOut.reserveCapacity(sorted.count)
        squarify(entries, in: safeBounds, output: &laidOut)

        let empty = TreemapRect(x: safeBounds.maxX, y: safeBounds.maxY, width: 0, height: 0)
        return sorted.map { value in
            TreemapTile(id: value.id, weight: value.weight, rect: laidOut[value.id] ?? empty)
        }
    }

    private static func sortedValues(_ values: [TreemapValue]) -> [TreemapValue] {
        values.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.id < $1.id
        }
    }

    private static func sanitized(_ rect: TreemapRect) -> TreemapRect {
        let x = rect.x.isFinite ? rect.x : 0
        let y = rect.y.isFinite ? rect.y : 0
        let width = rect.width.isFinite ? max(0, rect.width) : 0
        let height = rect.height.isFinite ? max(0, rect.height) : 0
        return TreemapRect(x: x, y: y, width: width, height: height)
    }

    private static func squarify(
        _ entries: [Entry],
        in initialBounds: TreemapRect,
        output: inout [String: TreemapRect]
    ) {
        var row: [Entry] = []
        var bounds = initialBounds
        var nextIndex = entries.startIndex

        while nextIndex < entries.endIndex {
            let candidate = entries[nextIndex]
            let shortSide = max(Double.leastNonzeroMagnitude, min(bounds.width, bounds.height))
            if row.isEmpty || worstAspectRatio(row + [candidate], shortSide: shortSide) <= worstAspectRatio(row, shortSide: shortSide) {
                row.append(candidate)
                nextIndex += 1
            } else {
                bounds = layout(row: row, in: bounds, output: &output)
                row.removeAll(keepingCapacity: true)
            }
        }

        if !row.isEmpty {
            _ = layout(row: row, in: bounds, output: &output)
        }
    }

    private static func worstAspectRatio(_ row: [Entry], shortSide: Double) -> Double {
        guard !row.isEmpty else { return .infinity }
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, let minimum = row.map(\.area).min(), let maximum = row.map(\.area).max(), minimum > 0 else {
            return .infinity
        }
        let sideSquared = shortSide * shortSide
        let sumSquared = sum * sum
        return max(sideSquared * maximum / sumSquared, sumSquared / (sideSquared * minimum))
    }

    @discardableResult
    private static func layout(
        row: [Entry],
        in bounds: TreemapRect,
        output: inout [String: TreemapRect]
    ) -> TreemapRect {
        let rowArea = row.reduce(0) { $0 + $1.area }
        guard rowArea > 0, bounds.width > 0, bounds.height > 0 else { return bounds }

        if bounds.width >= bounds.height {
            let stripWidth = min(bounds.width, rowArea / bounds.height)
            var y = bounds.y
            for (index, entry) in row.enumerated() {
                let height = index == row.count - 1 ? bounds.maxY - y : entry.area / max(stripWidth, .leastNonzeroMagnitude)
                output[entry.value.id] = TreemapRect(x: bounds.x, y: y, width: stripWidth, height: max(0, height))
                y += height
            }
            return TreemapRect(
                x: bounds.x + stripWidth,
                y: bounds.y,
                width: max(0, bounds.width - stripWidth),
                height: bounds.height
            )
        }

        let stripHeight = min(bounds.height, rowArea / bounds.width)
        var x = bounds.x
        for (index, entry) in row.enumerated() {
            let width = index == row.count - 1 ? bounds.maxX - x : entry.area / max(stripHeight, .leastNonzeroMagnitude)
            output[entry.value.id] = TreemapRect(x: x, y: bounds.y, width: max(0, width), height: stripHeight)
            x += width
        }
        return TreemapRect(
            x: bounds.x,
            y: bounds.y + stripHeight,
            width: bounds.width,
            height: max(0, bounds.height - stripHeight)
        )
    }
}
