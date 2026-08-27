import AppKit
import Darwin
import Foundation
import Security

private struct UninstallFileMetadata {
    let identity: FileIdentity
    let ownerUID: uid_t
}

private func uninstallFileMetadata(at url: URL) -> UninstallFileMetadata? {
    var information = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return lstat(path, &information)
    }
    guard result == 0 else { return nil }
    return UninstallFileMetadata(
        identity: FileIdentity(
            deviceID: FileIdentity.deviceID(fromRawValue: information.st_dev), inode: UInt64(information.st_ino),
            fileType: UInt16(information.st_mode & S_IFMT)
        ),
        ownerUID: information.st_uid
    )
}

public struct InstalledApplication: Identifiable, Hashable, Sendable {
    public var id: String { bundleURL.standardizedFileURL.path }
    public let bundleURL: URL
    public let bundleIdentifier: String?
    public let displayName: String
    public let version: String?
    public let allocatedBytesUpperBound: Int64
    public let bundleIdentity: FileIdentity?
    public let protectionReason: String?

    public var isProtected: Bool { protectionReason != nil }

    public init(
        bundleURL: URL, bundleIdentifier: String?, displayName: String, version: String?,
        allocatedBytesUpperBound: Int64, bundleIdentity: FileIdentity? = nil,
        protectionReason: String? = nil
    ) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.allocatedBytesUpperBound = allocatedBytesUpperBound
        self.bundleIdentity = bundleIdentity
        self.protectionReason = protectionReason
    }
}

public enum UninstallCandidateGroup: String, Codable, CaseIterable, Sendable {
    case applicationBundle
    case exactSettingsAndCaches
    case applicationData
    case sharedOrProtected
}

public struct UninstallCandidate: Identifiable, Hashable, Sendable {
    public var id: String { url.standardizedFileURL.path }
    public let url: URL
    public let group: UninstallCandidateGroup
    public let reason: String
    public let allocatedBytesUpperBound: Int64
    public let isDirectory: Bool
    public let isPackage: Bool
    public let expectedIdentity: FileIdentity?
    public let isRemovable: Bool
    public let isSelectedByDefault: Bool

    public init(
        url: URL, group: UninstallCandidateGroup, reason: String,
        allocatedBytesUpperBound: Int64, isDirectory: Bool, isPackage: Bool,
        expectedIdentity: FileIdentity? = nil,
        isRemovable: Bool, isSelectedByDefault: Bool
    ) {
        self.url = url
        self.group = group
        self.reason = reason
        self.allocatedBytesUpperBound = allocatedBytesUpperBound
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.expectedIdentity = expectedIdentity
        self.isRemovable = isRemovable
        self.isSelectedByDefault = isSelectedByDefault
    }
}

public struct UninstallPlan: Sendable {
    public let application: InstalledApplication
    public let candidates: [UninstallCandidate]
    public let isRunning: Bool
    public let blockingReason: String?
    public let generatedAt: Date

    public var canProceed: Bool { blockingReason == nil && !application.isProtected }
    public var defaultCandidateIDs: Set<String> {
        Set(candidates.filter { $0.isRemovable && $0.isSelectedByDefault }.map(\.id))
    }

    public init(
        application: InstalledApplication, candidates: [UninstallCandidate], isRunning: Bool,
        blockingReason: String? = nil, generatedAt: Date = Date()
    ) {
        self.application = application
        self.candidates = candidates
        self.isRunning = isRunning
        self.blockingReason = blockingReason
        self.generatedAt = generatedAt
    }
}

public enum UninstallStatus: String, Codable, Sendable {
    case succeeded
    case partial
    case blockedProtected
    case blockedRunning
    case bundleFailed
    case cancelled
}

public struct UninstallResult: Sendable {
    public let application: InstalledApplication
    public let status: UninstallStatus
    public let bundleResult: TrashOperationResult?
    public let associatedResults: [TrashOperationResult]
    public let message: String?

    public var recoverableBytesUpperBound: Int64 {
        let bundleBytes = bundleResult?.status == .trashed ? (bundleResult?.allocatedBytesUpperBound ?? 0) : 0
        return bundleBytes + associatedResults.reduce(0) { $0 + ($1.status == .trashed ? $1.allocatedBytesUpperBound : 0) }
    }

    public init(
        application: InstalledApplication, status: UninstallStatus,
        bundleResult: TrashOperationResult? = nil, associatedResults: [TrashOperationResult] = [],
        message: String? = nil
    ) {
        self.application = application
        self.status = status
        self.bundleResult = bundleResult
        self.associatedResults = associatedResults
        self.message = message
    }
}

public actor ApplicationDiscoveryService {
    private let fileManager: FileManager
    private let homeURL: URL

    public init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL
    }

    /// Finds app bundles without traversing inside them. Additional URLs let the explorer
    /// contribute application bundles encountered outside the two conventional roots.
    public func discover(additionalURLs: [URL] = []) async -> [InstalledApplication] {
        var bundleURLs = additionalURLs.filter { $0.pathExtension.lowercased() == "app" }
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     homeURL.appendingPathComponent("Applications", isDirectory: true)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                if url.pathExtension.lowercased() == "app" {
                    bundleURLs.append(url)
                    enumerator.skipDescendants()
                }
            }
        }

        var seen: Set<String> = []
        return bundleURLs.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return makeApplication(at: url)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Resolves an app encountered directly by the Explorer and captures its lstat identity.
    public func application(at bundleURL: URL) -> InstalledApplication? {
        guard bundleURL.pathExtension.lowercased() == "app" else { return nil }
        return makeApplication(at: bundleURL)
    }

    private func makeApplication(at url: URL) -> InstalledApplication? {
        guard fileManager.fileExists(atPath: url.path), let bundle = Bundle(url: url) else { return nil }
        let identifier = bundle.bundleIdentifier
        let info = bundle.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String)
        let metadata = uninstallFileMetadata(at: url)
        let protection = Self.protectionReason(url: url, identifier: identifier, displayName: name)
            ?? (metadata == nil ? "Impossible de capturer l’identité du bundle." : nil)
            ?? (metadata?.ownerUID == 0 ? "Application appartenant à root : aucun helper administrateur n’est utilisé." : nil)
        return InstalledApplication(
            bundleURL: url, bundleIdentifier: identifier, displayName: name, version: version,
            allocatedBytesUpperBound: 0, bundleIdentity: metadata?.identity,
            protectionReason: protection
        )
    }

    private static func protectionReason(url: URL, identifier: String?, displayName: String) -> String? {
        let path = url.standardizedFileURL.path
        let identifierLower = identifier?.lowercased()
        if path == "/System" || path.hasPrefix("/System/") { return "Application système protégée." }
        if identifierLower?.hasPrefix("com.apple.") == true { return "Application Apple protégée." }
        if displayName.caseInsensitiveCompare("StorageScope") == .orderedSame
            || identifierLower?.contains("storagescope") == true {
            return "StorageScope ne peut pas se désinstaller lui-même."
        }
        guard let identifier, BundleIdentifierValidator.isValid(identifier) else {
            return "CFBundleIdentifier absent ou invalide : association non fiable."
        }
        return nil
    }
}

public actor AppAssociationFinder {
    private let fileManager: FileManager
    private let homeURL: URL

    public init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL
    }

    /// Uses only exact bundle identifier paths or its dot-delimited namespace. It never
    /// searches by the human-readable application name.
    public func candidates(for application: InstalledApplication) async -> [UninstallCandidate] {
        guard let bundleID = application.bundleIdentifier,
              BundleIdentifierValidator.isValid(bundleID),
              !bundleID.lowercased().hasPrefix("com.apple.") else { return [] }
        var candidates: [UninstallCandidate] = []

        appendIfPresent(
            application.bundleURL, group: .applicationBundle,
            reason: "Bundle principal de l’application.", removable: !application.isProtected,
            selected: !application.isProtected, to: &candidates
        )

        let library = homeURL.appendingPathComponent("Library", isDirectory: true)
        let exact: [([String], String)] = [
            (["Preferences", "\(bundleID).plist"], "Préférences portant exactement l’identifiant du bundle."),
            (["Caches", bundleID], "Cache portant exactement l’identifiant du bundle."),
            (["Logs", bundleID], "Journaux portant exactement l’identifiant du bundle."),
            (["Saved Application State", "\(bundleID).savedState"], "État de fenêtre enregistré de l’application."),
            (["WebKit", bundleID], "Cache WebKit propre à l’application."),
            (["Cookies", "\(bundleID).binarycookies"], "Cookies propres à l’application."),
            (["HTTPStorages", bundleID], "Stockage HTTP propre à l’application.")
        ]
        for (components, reason) in exact {
            guard let candidateURL = safeDescendant(of: library, components: components) else { continue }
            appendIfPresent(candidateURL, group: .exactSettingsAndCaches,
                reason: reason, removable: true, selected: true, to: &candidates)
        }

        appendNamespacedFiles(
            in: library.appendingPathComponent("Preferences/ByHost", isDirectory: true),
            bundleID: bundleID, group: .exactSettingsAndCaches,
            reason: "Préférences ByHost dans l’espace de noms exact du bundle.",
            removable: true, selected: true, to: &candidates
        )

        let dataPaths: [([String], String)] = [
            (["Application Support", bundleID], "Données persistantes de l’application."),
            (["Containers", bundleID], "Conteneur sandbox pouvant contenir des documents."),
            (["Application Scripts", bundleID], "Scripts propres au conteneur de l’application.")
        ]
        for (components, reason) in dataPaths {
            guard let candidateURL = safeDescendant(of: library, components: components) else { continue }
            appendIfPresent(candidateURL, group: .applicationData,
                reason: reason, removable: true, selected: false, to: &candidates)
        }

        let protectedRoots = [
            URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ]
        for root in protectedRoots {
            appendNamespacedFiles(
                in: root, bundleID: bundleID, group: .sharedOrProtected,
                reason: "Composant privilégié ou partagé : signalé uniquement.",
                removable: false, selected: false, to: &candidates
            )
        }

        for groupID in applicationGroupIdentifiers(at: application.bundleURL) {
            guard let groupURL = safeDescendant(
                of: library, components: ["Group Containers", groupID]
            ) else { continue }
            appendIfPresent(
                groupURL,
                group: .sharedOrProtected,
                reason: "Conteneur de groupe déclaré par les droits de signature : signalé uniquement.",
                removable: false, selected: false, to: &candidates
            )
        }
        for helperID in privilegedHelperIdentifiers(at: application.bundleURL) {
            let helperRoot = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true)
            guard let helperURL = safeDescendant(of: helperRoot, components: [helperID]) else { continue }
            appendIfPresent(
                helperURL,
                group: .sharedOrProtected,
                reason: "Helper privilégié déclaré par l’application : signalé uniquement.",
                removable: false, selected: false, to: &candidates
            )
        }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }.sorted {
            if $0.group != $1.group { return $0.group.rawValue < $1.group.rawValue }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private func appendNamespacedFiles(
        in root: URL, bundleID: String, group: UninstallCandidateGroup, reason: String,
        removable: Bool, selected: Bool, to candidates: inout [UninstallCandidate]
    ) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
        ) else { return }
        for child in children {
            let name = child.lastPathComponent
            let stem = child.deletingPathExtension().lastPathComponent
            guard name == bundleID || stem == bundleID || name.hasPrefix(bundleID + ".") else { continue }
            appendIfPresent(child, group: group, reason: reason, removable: removable,
                selected: selected, to: &candidates)
        }
    }

    private func appendIfPresent(
        _ url: URL, group: UninstallCandidateGroup, reason: String, removable: Bool,
        selected: Bool, to candidates: inout [UninstallCandidate]
    ) {
        guard fileManager.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return }
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
        ])
        let metadata = uninstallFileMetadata(at: url)
        let canRemove = removable && metadata != nil && metadata?.ownerUID != 0
        candidates.append(UninstallCandidate(
            url: url, group: group, reason: reason,
            allocatedBytesUpperBound: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0),
            isDirectory: values?.isDirectory == true, isPackage: values?.isPackage == true,
            expectedIdentity: metadata?.identity,
            isRemovable: canRemove, isSelectedByDefault: selected && canRemove
        ))
    }

    private func applicationGroupIdentifiers(at bundleURL: URL) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return [] }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups.filter(BundleIdentifierValidator.isValid)
    }

    private func privilegedHelperIdentifiers(at bundleURL: URL) -> [String] {
        guard let dictionary = Bundle(url: bundleURL)?.infoDictionary?["SMPrivilegedExecutables"] as? [String: Any] else {
            return []
        }
        return dictionary.keys.filter(BundleIdentifierValidator.isValid)
    }

    private func safeDescendant(of root: URL, components: [String]) -> URL? {
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else {
            return nil
        }
        let candidate = components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }
}

public actor UninstallService {
    private let associationFinder: AppAssociationFinder
    private let trashService: TrashService

    public init(
        associationFinder: AppAssociationFinder = AppAssociationFinder(),
        trashService: TrashService = TrashService()
    ) {
        self.associationFinder = associationFinder
        self.trashService = trashService
    }

    public func makePlan(for application: InstalledApplication) async -> UninstallPlan {
        let candidates = await associationFinder.candidates(for: application)
        let running = await applicationIsRunning(application)
        let identifierBlock: String?
        if let identifier = application.bundleIdentifier, BundleIdentifierValidator.isValid(identifier) {
            identifierBlock = nil
        } else {
            identifierBlock = "CFBundleIdentifier invalide : aucun chemin associé ne sera construit."
        }
        return UninstallPlan(
            application: application, candidates: candidates, isRunning: running,
            blockingReason: application.protectionReason ?? identifierBlock
        )
    }

    /// Requests the application's regular terminate path and never force-quits it.
    public func requestQuit(_ application: InstalledApplication) async -> Bool {
        guard let identifier = application.bundleIdentifier,
              BundleIdentifierValidator.isValid(identifier) else { return false }
        let runningApplications = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        }
        guard !runningApplications.isEmpty else { return true }
        await MainActor.run { runningApplications.forEach { _ = $0.terminate() } }
        for _ in 0..<30 {
            if Task.isCancelled { return false }
            if !(await applicationIsRunning(application)) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Moves the app bundle first. Associated data is untouched if that mandatory step fails.
    public func uninstall(
        _ plan: UninstallPlan, selectedCandidateIDs: Set<String>, requestQuitIfRunning: Bool = false
    ) async -> UninstallResult {
        let app = plan.application
        guard plan.canProceed else {
            return UninstallResult(application: app, status: .blockedProtected,
                message: plan.blockingReason ?? app.protectionReason)
        }
        guard let bundleIdentifier = app.bundleIdentifier,
              BundleIdentifierValidator.isValid(bundleIdentifier) else {
            return UninstallResult(application: app, status: .blockedProtected,
                message: "CFBundleIdentifier invalide.")
        }
        if await applicationIsRunning(app) {
            guard requestQuitIfRunning, await requestQuit(app) else {
                return UninstallResult(application: app, status: .blockedRunning,
                    message: "L’application est ouverte. Quitte-la normalement avant la désinstallation.")
            }
        }
        if Task.isCancelled { return UninstallResult(application: app, status: .cancelled) }

        guard let bundleCandidate = plan.candidates.first(where: { $0.group == .applicationBundle && $0.url == app.bundleURL }) else {
            return UninstallResult(application: app, status: .bundleFailed,
                message: "Le bundle principal n’existe plus ou n’a pas pu être validé.")
        }
        guard let expectedBundleIdentity = bundleCandidate.expectedIdentity,
              uninstallFileMetadata(at: bundleCandidate.url)?.identity == expectedBundleIdentity,
              app.bundleIdentity == expectedBundleIdentity else {
            return UninstallResult(application: app, status: .bundleFailed,
                message: "Le bundle a été remplacé ou modifié depuis la préparation du plan.")
        }
        let bundleItem = fileSystemItem(from: bundleCandidate, category: .application)
        let bundlePreflight = TrashPreflightResult(
            item: bundleItem, identity: expectedBundleIdentity,
            authorization: .verifiedApplicationAssociation(bundleIdentifier: bundleIdentifier),
            errorDescription: nil
        )
        let bundleAttempt = await trashService.trashWithResults([bundlePreflight]).first
        guard let bundleResult = bundleAttempt, bundleResult.status == .trashed else {
            return UninstallResult(application: app, status: .bundleFailed, bundleResult: bundleAttempt,
                message: "Le bundle principal n’a pas été déplacé ; aucun fichier associé n’a été touché.")
        }

        let selectedAssociations = plan.candidates.filter {
            $0.group != .applicationBundle && $0.isRemovable && selectedCandidateIDs.contains($0.id)
        }
        let validAssociations = selectedAssociations.filter {
            $0.expectedIdentity != nil && uninstallFileMetadata(at: $0.url)?.identity == $0.expectedIdentity
        }
        let invalidResults = selectedAssociations.filter {
            $0.expectedIdentity == nil || uninstallFileMetadata(at: $0.url)?.identity != $0.expectedIdentity
        }.map { candidate in
            TrashOperationResult(
                originalURL: candidate.url, expectedIdentity: candidate.expectedIdentity,
                status: .failed, allocatedBytesUpperBound: candidate.allocatedBytesUpperBound,
                errorDescription: "L’élément a changé depuis la préparation du plan."
            )
        }
        let associatedPreflights = validAssociations.map { candidate in
            TrashPreflightResult(
                item: fileSystemItem(from: candidate, category: .other),
                identity: candidate.expectedIdentity,
                authorization: .verifiedApplicationAssociation(bundleIdentifier: bundleIdentifier),
                errorDescription: nil
            )
        }
        let associatedResults = invalidResults + (await trashService.trashWithResults(associatedPreflights))
        let failed = associatedResults.contains { $0.status == .failed }
        let cancelled = associatedResults.contains { $0.status == .cancelled } || Task.isCancelled
        return UninstallResult(
            application: app, status: cancelled ? .cancelled : (failed ? .partial : .succeeded),
            bundleResult: bundleResult, associatedResults: associatedResults,
            message: failed ? "L’application a été déplacée, mais certains éléments associés ont échoué." : nil
        )
    }

    private func applicationIsRunning(_ application: InstalledApplication) async -> Bool {
        guard let identifier = application.bundleIdentifier,
              BundleIdentifierValidator.isValid(identifier) else { return false }
        return await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
        }
    }

    private func fileSystemItem(from candidate: UninstallCandidate, category: ItemCategory) -> FileSystemItem {
        FileSystemItem(
            url: candidate.url, logicalSize: candidate.allocatedBytesUpperBound,
            allocatedSize: candidate.allocatedBytesUpperBound, isDirectory: candidate.isDirectory,
            isSymbolicLink: false, isPackage: candidate.isPackage,
            category: category, safety: .review
        )
    }
}
