import Foundation

public enum SelectionNormalizer {
    /// Removes duplicate paths and descendants whose selected parent directory already covers them.
    /// This prevents double-counted reclaimable bytes and avoids trashing a child after its parent.
    public static func normalize(_ items: [FileSystemItem]) -> [FileSystemItem] {
        var unique: [String: FileSystemItem] = [:]
        for item in items { unique[item.url.standardizedFileURL.path] = item }
        let sorted = unique.values.sorted {
            let lhsDepth = $0.url.pathComponents.count
            let rhsDepth = $1.url.pathComponents.count
            return lhsDepth == rhsDepth ? $0.url.path < $1.url.path : lhsDepth < rhsDepth
        }
        var result: [FileSystemItem] = []
        var selectedDirectories: [String] = []
        for item in sorted {
            let path = item.url.standardizedFileURL.path
            if selectedDirectories.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            result.append(item)
            if item.isDirectory { selectedDirectories.append(path) }
        }
        return result
    }
}
