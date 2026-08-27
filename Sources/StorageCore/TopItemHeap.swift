import Foundation

/// A bounded min-heap that retains only the largest file-system items.
/// Insertions are O(log limit), avoiding a linear minimum search for every file.
struct TopItemHeap: Sendable {
    private(set) var items: [FileSystemItem] = []
    let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
        items.reserveCapacity(min(self.limit, 256))
    }

    mutating func insert(_ item: FileSystemItem) {
        if items.count < limit {
            items.append(item)
            siftUp(from: items.count - 1)
        } else if let smallest = items.first, item.allocatedSize > smallest.allocatedSize {
            items[0] = item
            siftDown(from: 0)
        }
    }

    func descending() -> [FileSystemItem] {
        items.sorted { $0.allocatedSize > $1.allocatedSize }
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].allocatedSize < items[parent].allocatedSize else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < items.count else { return }
            let right = left + 1
            let smallest = right < items.count && items[right].allocatedSize < items[left].allocatedSize ? right : left
            guard items[smallest].allocatedSize < items[parent].allocatedSize else { return }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
