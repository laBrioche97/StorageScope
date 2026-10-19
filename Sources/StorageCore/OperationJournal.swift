import Foundation

public enum OperationJournal {
    private static let lock = NSLock()
    public static func append(operation: String, path: String, status: String, message: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StorageScope/History", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("operations.jsonl")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4 * 1_048_576 {
            let previous = root.appendingPathComponent("operations.previous.jsonl")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: url, to: previous)
        }
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        var record = ["at": ISO8601DateFormatter().string(from: Date()), "operation": operation, "path": path, "status": status]
        if let message { record["message"] = message }
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
