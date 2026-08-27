import Foundation

public enum CleanupSuggestionKind: String, Codable, Sendable {
    case oldInstallers
    case largeOldDownloads
    case xcodeDerivedData
    case xcodeArchives
    case xcodeDeviceSupport
    case toolCaches
    case applicationCaches
    case staleNodeModules
    case diagnosticReports
    case iosBackups
    case trashReview
}

public enum CleanupConfidence: String, Codable, Sendable {
    case high = "Confiance élevée"
    case medium = "À vérifier"
    case reviewOnly = "Inspection uniquement"
}

public enum CleanupAction: String, Codable, Sendable {
    case reviewAndTrash
    case revealOnly
}

public struct CleanupSuggestion: Identifiable, Codable, Sendable {
    public let id: CleanupSuggestionKind
    public let title: String
    public let explanation: String
    public let potentialBytes: Int64
    public let itemCount: Int
    public let items: [FileSystemItem]
    public let confidence: CleanupConfidence
    public let action: CleanupAction
}

public struct CleanupReport: Codable, Sendable {
    public let suggestions: [CleanupSuggestion]
    public let uniquePotentialBytes: Int64
    public let isComplete: Bool
    public let permissionErrors: Int
    public let generatedAt: Date
}

/// Single-pass, allowlist-based cleanup analysis. It never reads file contents and
/// never labels arbitrary personal documents, VMs, backups or app data as disposable.
public struct CleanupAnalyzer: Sendable {
    private struct FileBucket: Sendable {
        var heap = TopItemHeap(limit: 100)
        var bytes: Int64 = 0
        var count = 0

        mutating func add(_ item: FileSystemItem) {
            heap.insert(item)
            bytes = SaturatingArithmetic.addNonnegative(bytes, item.allocatedSize)
            count = SaturatingArithmetic.addNonnegative(count, 1)
        }
    }

    private let homePath: String
    private let now: Date
    private var installers = FileBucket()
    private var diagnostics = FileBucket()
    private var largeOldDownloads = FileBucket()
    private var packageManifestParents: Set<String> = []
    private var lockfileParents: Set<String> = []

    public init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) {
        homePath = homeURL.standardizedFileURL.path
        self.now = now
    }

    public mutating func observeFile(_ item: FileSystemItem) {
        let path = item.url.path
        guard !item.isSymbolicLink else { return }
        let age = item.modificationDate.map { now.timeIntervalSince($0) } ?? 0
        let ext = item.fileExtension

        let downloads = homePath + "/Downloads"
        if isDescendant(path, of: downloads), ["dmg", "pkg", "iso"].contains(ext), item.allocatedSize >= 50 * 1_048_576, age >= 30 * 86_400 {
            installers.add(item)
        }

        if isDescendant(path, of: downloads), item.allocatedSize >= 1_073_741_824, age >= 180 * 86_400,
           !["dmg", "pkg", "iso"].contains(ext) {
            largeOldDownloads.add(item)
        }

        let diagnosticRoot = homePath + "/Library/Logs/DiagnosticReports"
        if isDescendant(path, of: diagnosticRoot), ["ips", "crash", "hang"].contains(ext), age >= 30 * 86_400 {
            diagnostics.add(item)
        }


        let parent = item.parentPath
        if item.name == "package.json" { packageManifestParents.insert(parent) }
        if ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"].contains(item.name) {
            lockfileParents.insert(parent)
        }
    }

    public func makeReport(directories: [FileSystemItem], permissionErrors: Int, isComplete: Bool) -> CleanupReport {
        var claimedPaths: [String] = []
        var suggestions: [CleanupSuggestion] = []

        let directoryRules: [(CleanupSuggestionKind, (FileSystemItem) -> Bool)] = [
            (.trashReview, { $0.url.path == homePath + "/.Trash" }),
            (.xcodeDerivedData, { item in
                let parent = item.url.deletingLastPathComponent().path
                let age = item.modificationDate.map { now.timeIntervalSince($0) } ?? 0
                return parent == homePath + "/Library/Developer/Xcode/DerivedData" && item.allocatedSize >= 100 * 1_048_576 && age >= 14 * 86_400
            }),
            (.xcodeArchives, { item in
                let parent = item.url.deletingLastPathComponent().path
                let age = item.modificationDate.map { now.timeIntervalSince($0) } ?? 0
                return parent.hasPrefix(homePath + "/Library/Developer/Xcode/Archives/") && item.allocatedSize >= 1_073_741_824 && age >= 180 * 86_400
            }),
            (.xcodeDeviceSupport, { item in
                let parent = item.url.deletingLastPathComponent().path
                let age = item.modificationDate.map { now.timeIntervalSince($0) } ?? 0
                return parent == homePath + "/Library/Developer/Xcode/iOS DeviceSupport" && item.allocatedSize >= 1_073_741_824 && age >= 90 * 86_400
            }),
            (.toolCaches, { item in
                let path = item.url.path
                let roots = [
                    homePath + "/.npm/_cacache", homePath + "/.cache/pip", homePath + "/.gradle/caches",
                    homePath + "/Library/Caches/Homebrew", homePath + "/Library/Caches/pip",
                    homePath + "/Library/Caches/Yarn", homePath + "/Library/Caches/CocoaPods",
                    homePath + "/Library/Caches/org.swift.swiftpm", homePath + "/Library/pnpm/store"
                ]
                return roots.contains(path) && item.allocatedSize >= 100 * 1_048_576
            }),
            (.applicationCaches, { item in
                let url = item.url
                return url.deletingLastPathComponent().path == homePath + "/Library/Caches" &&
                    !item.name.lowercased().hasPrefix("com.apple.") && item.allocatedSize >= 250 * 1_048_576
            }),
            (.staleNodeModules, { item in
                let path = item.url.path
                let project = item.url.deletingLastPathComponent().path
                let age = item.modificationDate.map { now.timeIntervalSince($0) } ?? 0
                return item.name == "node_modules" && packageManifestParents.contains(project) && lockfileParents.contains(project) &&
                    isInsideHome(path) && !isDenied(path) && item.allocatedSize >= 250 * 1_048_576 && age >= 60 * 86_400
            }),
            (.iosBackups, { item in
                let parent = item.url.deletingLastPathComponent().path
                return parent == homePath + "/Library/Application Support/MobileSync/Backup" && item.allocatedSize >= 1_073_741_824
            })
        ]

        var grouped: [CleanupSuggestionKind: [FileSystemItem]] = [:]
        for (kind, matches) in directoryRules {
            let candidates = directories.filter(matches).sorted { $0.url.path.count < $1.url.path.count }
            for item in candidates {
                let path = item.url.path
                guard !claimedPaths.contains(where: { isDescendant(path, of: $0) || isDescendant($0, of: path) }) else { continue }
                claimedPaths.append(path)
                grouped[kind, default: []].append(item)
            }
        }

        appendDirectorySuggestion(.xcodeDerivedData, items: grouped[.xcodeDerivedData] ?? [], title: "Données de compilation Xcode anciennes", explanation: "DerivedData est régénérable. La prochaine compilation sera plus lente.", confidence: .medium, action: .reviewAndTrash, to: &suggestions)
        appendDirectorySuggestion(.xcodeArchives, items: grouped[.xcodeArchives] ?? [], title: "Anciennes archives Xcode", explanation: "Ces archives peuvent être utiles pour symboliser un crash ou republier une version. Examine-les avant suppression.", confidence: .reviewOnly, action: .revealOnly, to: &suggestions)
        appendDirectorySuggestion(.xcodeDeviceSupport, items: grouped[.xcodeDeviceSupport] ?? [], title: "Ancien support d’appareils Xcode", explanation: "Xcode pourra retélécharger ces fichiers si un ancien appareil est reconnecté.", confidence: .reviewOnly, action: .revealOnly, to: &suggestions)
        appendDirectorySuggestion(.toolCaches, items: grouped[.toolCaches] ?? [], title: "Caches d’outils de développement", explanation: "Caches npm, pip, Homebrew ou Yarn explicitement reconnus. Leur contenu pourra être retéléchargé.", confidence: .high, action: .reviewAndTrash, to: &suggestions)
        appendDirectorySuggestion(.applicationCaches, items: grouped[.applicationCaches] ?? [], title: "Caches volumineux d’applications tierces", explanation: "Ces caches peuvent être actifs et seront recréés. Examine-les avant toute action.", confidence: .reviewOnly, action: .revealOnly, to: &suggestions)
        appendDirectorySuggestion(.staleNodeModules, items: grouped[.staleNodeModules] ?? [], title: "Anciens dossiers node_modules", explanation: "Dépendances reconstruisibles, mais une réinstallation et parfois Internet seront nécessaires.", confidence: .reviewOnly, action: .revealOnly, to: &suggestions)
        appendDirectorySuggestion(.iosBackups, items: grouped[.iosBackups] ?? [], title: "Sauvegardes iPhone ou iPad volumineuses", explanation: "Ces sauvegardes peuvent contenir des données personnelles irremplaçables. Examine-les dans Finder ou Réglages.", confidence: .reviewOnly, action: .revealOnly, to: &suggestions)
        appendDirectorySuggestion(.trashReview, items: grouped[.trashReview] ?? [], title: "Contenu de la Corbeille", explanation: "Vider la Corbeille est irréversible. Ouvre-la et vérifie son contenu manuellement.", confidence: .reviewOnly, action: .revealOnly, to: &suggestions)

        let claimed = claimedPaths
        appendFileSuggestion(.oldInstallers, bucket: installers, excluding: claimed, title: "Anciens installateurs téléchargés", explanation: "Fichiers DMG, PKG ou ISO de plus de 30 jours dans Téléchargements.", confidence: .medium, to: &suggestions)
        appendFileSuggestion(.largeOldDownloads, bucket: largeOldDownloads, excluding: claimed, title: "Gros téléchargements anciens", explanation: "Fichiers de plus de 1 Go non modifiés depuis au moins six mois. Vérifie qu’ils ne sont plus utiles.", confidence: .reviewOnly, action: .revealOnly, to: &suggestions)
        appendFileSuggestion(.diagnosticReports, bucket: diagnostics, excluding: claimed, title: "Anciens rapports de diagnostic", explanation: "Rapports .ips, .crash et .hang de plus de 30 jours.", confidence: .high, to: &suggestions)

        suggestions.sort { $0.potentialBytes > $1.potentialBytes }
        return CleanupReport(
            suggestions: suggestions,
            uniquePotentialBytes: suggestions.reduce(Int64(0)) {
                SaturatingArithmetic.addNonnegative($0, $1.potentialBytes)
            },
            isComplete: isComplete,
            permissionErrors: permissionErrors,
            generatedAt: now
        )
    }

    private func appendDirectorySuggestion(_ kind: CleanupSuggestionKind, items: [FileSystemItem], title: String, explanation: String, confidence: CleanupConfidence, action: CleanupAction, to suggestions: inout [CleanupSuggestion]) {
        guard !items.isEmpty else { return }
        let sorted = items.sorted { $0.allocatedSize > $1.allocatedSize }
        let potentialBytes = sorted.reduce(Int64(0)) {
            SaturatingArithmetic.addNonnegative($0, $1.allocatedSize)
        }
        suggestions.append(CleanupSuggestion(id: kind, title: title, explanation: explanation, potentialBytes: potentialBytes, itemCount: sorted.count, items: Array(sorted.prefix(100)), confidence: confidence, action: action))
    }

    private func appendFileSuggestion(_ kind: CleanupSuggestionKind, bucket: FileBucket, excluding claimed: [String], title: String, explanation: String, confidence: CleanupConfidence, action: CleanupAction = .reviewAndTrash, to suggestions: inout [CleanupSuggestion]) {
        let items = bucket.heap.descending().filter { item in !claimed.contains(where: { isDescendant(item.url.path, of: $0) }) }
        guard !items.isEmpty else { return }
        // File rule roots do not overlap current directory rules, so the observed aggregate
        // remains exact for v1. It is still described as an APFS upper bound in the UI.
        suggestions.append(CleanupSuggestion(id: kind, title: title, explanation: explanation, potentialBytes: bucket.bytes, itemCount: bucket.count, items: items, confidence: confidence, action: action))
    }

    private func isInsideHome(_ path: String) -> Bool { path == homePath || path.hasPrefix(homePath + "/") }

    private func isDescendant(_ path: String, of parent: String) -> Bool {
        path == parent || path.hasPrefix(parent + "/")
    }

    private func isDenied(_ path: String) -> Bool {
        let denied = [
            "/Library/Mail", "/Library/Messages", "/Library/Safari", "/Library/Photos",
            "/Library/Containers", "/Library/Group Containers", "/Library/Application Support",
            "/Library/Mobile Documents", "/Library/CloudStorage", "/Library/Keychains",
            "/Documents", "/Desktop", "/Pictures"
        ]
        return denied.contains { isDescendant(path, of: homePath + $0) } || path.contains("/.git/")
    }
}
