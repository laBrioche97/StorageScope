import Darwin
import Foundation

public enum InstallationSizeState: String, Hashable, Sendable {
    case calculating, declared, measured, partial, unavailable
}

public struct InstallationSize: Hashable, Sendable {
    public let bytes: Int64?
    public let state: InstallationSizeState
    public init(bytes: Int64? = nil, state: InstallationSizeState = .calculating) {
        self.bytes = bytes.map { max(0, $0) }; self.state = state
    }
    public var label: String {
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        switch state {
        case .calculating: return size.map { "\($0) · Calcul en cours" } ?? "Calcul en cours…"
        case .declared: return size.map { "\($0) · Déclarée" } ?? "Indisponible"
        case .measured: return size.map { "\($0) · Mesurée" } ?? "Indisponible"
        case .partial: return size.map { "Au moins \($0) · Partielle" } ?? "Estimation partielle"
        case .unavailable: return "Taille indisponible"
        }
    }
}

/// Reads metadata only: never opens file contents, downloads cloud data or follows links.
/// A structured task group bounds filesystem work to two installations at a time.
public enum InstallationSizeService {
    private static let limiter = RecursiveReadBudget.shared
    public static func measure(_ url: URL) -> InstallationSize {
        let root = url.standardizedFileURL
        guard !DeletionSafetyPolicy.isCloudPath(root.path), !hasLinkedAncestor(root),
              let start = identity(root), start.type == S_IFDIR else {
            return InstallationSize(state: .unavailable)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        var total: Int64 = 0, partial = false
        var seen = Set<String>()
        let manager = FileManager()
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in partial = true; return true }) else {
            return InstallationSize(state: .unavailable)
        }
        for case let child as URL in enumerator {
            if Task.isCancelled { return InstallationSize(bytes: total, state: .partial) }
            do {
                let values = try child.resourceValues(forKeys: keys)
                guard let entry = identity(child), entry.device == start.device else {
                    enumerator.skipDescendants(); partial = true; continue
                }
                if values.isSymbolicLink == true || values.isUbiquitousItem == true || DeletionSafetyPolicy.isCloudPath(child.path) {
                    enumerator.skipDescendants(); partial = true; continue
                }
                if values.isDirectory != true, seen.insert("\(entry.device):\(entry.inode)").inserted {
                    if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                        total = total > Int64.max - Int64(size) ? Int64.max : total + Int64(size)
                    } else { partial = true }
                }
            } catch { enumerator.skipDescendants(); partial = true }
        }
        guard identity(root) == start, !hasLinkedAncestor(root) else { return InstallationSize(state: .unavailable) }
        return InstallationSize(bytes: total, state: partial ? .partial : .measured)
    }

    public static func measureAll(_ urls: [URL], onBatch: @escaping @Sendable ([String: InstallationSize]) async -> Void) async {
        let unique = Array(Set(urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        await withTaskGroup(of: (String, InstallationSize).self) { group in
            var next = 0, pending: [String: InstallationSize] = [:]
            let clock = ContinuousClock()
            var last = clock.now
            func submit() {
                guard next < unique.count, !Task.isCancelled else { return }
                let url = unique[next]; next += 1
                group.addTask {
                    await limiter.acquire()
                    let size = Task.isCancelled ? InstallationSize(state: .unavailable) : measure(url)
                    await limiter.release()
                    return (url.path, size)
                }
            }
            submit(); submit()
            for await (path, size) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                pending[path] = size
                if last.duration(to: clock.now) >= .milliseconds(250) || next == unique.count {
                    await onBatch(pending); pending.removeAll(); last = clock.now
                }
                submit()
            }
            if !pending.isEmpty, !Task.isCancelled { await onBatch(pending) }
        }
    }

    private struct Identity: Equatable { let device: dev_t; let inode: ino_t; let type: mode_t }
    private static func identity(_ url: URL) -> Identity? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return Identity(device: value.st_dev, inode: value.st_ino, type: value.st_mode & S_IFMT)
    }
    private static func hasLinkedAncestor(_ url: URL) -> Bool {
        var current = url
        while current.path != "/" {
            guard let value = identity(current), value.type != S_IFLNK else { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
}
