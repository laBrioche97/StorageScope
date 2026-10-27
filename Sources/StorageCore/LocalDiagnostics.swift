import Darwin
import Foundation

/// Local records only. Callers provide action names and error domains/codes, never file contents.
public final class LocalDiagnostics: @unchecked Sendable {
    public static let shared = LocalDiagnostics()
    public let directory: URL
    private let lock = NSLock()
    private var version = "unknown"
    private let session = UUID().uuidString
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StorageScope/Diagnostics")) {
        self.directory = directory
    }
    @discardableResult public func begin(version: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.version = version
        do {
            try prepare()
            let marker = directory.appendingPathComponent("session.json")
            var interrupted = false
            if let data = try? Data(contentsOf: marker),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = previous["pid"] as? Int32 {
                interrupted = kill(pid, 0) != 0 && errno == ESRCH
            }
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "session": session]).write(to: marker, options: .atomic)
            try write(action: "démarrage", detail: interrupted ? "Session précédente interrompue ; code de sortie inconnu" : "Ouverture normale")
            return interrupted
        } catch { return false }
    }
    public func record(action: String, detail: String = "") {
        lock.lock(); defer { lock.unlock() }
        try? prepare(); try? write(action: action, detail: detail)
    }
    public func record(action: String, error: any Error) {
        let value = error as NSError
        record(action: action, detail: "\(value.domain) · code \(value.code)")
    }
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        try? write(action: "arrêt normal", detail: "code 0")
        let marker = directory.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: marker),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["session"] as? String == session {
            try? FileManager.default.removeItem(at: marker)
        }
    }
    public func export(to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("StorageScope-crashes.log") && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var data = Data("StorageScope — diagnostics locaux, aucun envoi automatique\n".utf8)
        for file in files { data.append(try Data(contentsOf: file)) }
        try data.write(to: destination, options: .atomic)
    }
    private func prepare() throws {
        var ancestor = directory
        while ancestor.path != "/" {
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CocoaError(.fileWriteNoPermission) }
            ancestor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func write(action: String, detail: String) throws {
        let manager = FileManager.default, file = directory.appendingPathComponent("StorageScope-crashes.log")
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CocoaError(.fileWriteNoPermission) }
        if (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 >= 2 * 1024 * 1024 {
            for index in stride(from: 5, through: 1, by: -1) {
                let destination = directory.appendingPathComponent("StorageScope-crashes.log.\(index)")
                let source = index == 1 ? file : directory.appendingPathComponent("StorageScope-crashes.log.\(index - 1)")
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: destination) }
            }
        }
        if !manager.fileExists(atPath: file.path) { _ = manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd()
        let entry = "\(ISO8601DateFormatter().string(from: Date())) · v\(version) · \(action.prefix(200)) · \(detail.prefix(12_000))\n"
        try handle.write(contentsOf: Data(entry.utf8)); try handle.synchronize()
    }
}
