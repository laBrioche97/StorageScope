import Foundation

/// Strict validation for identifiers that will be used as path components. This is
/// intentionally narrower than arbitrary plist strings: reverse-DNS components only.
public enum BundleIdentifierValidator {
    public static func isValid(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.utf8.count <= 255,
              !identifier.contains("/"), !identifier.contains("\\"),
              !identifier.contains(".."), !identifier.contains(":"),
              identifier.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }) else { return false }
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty, component.utf8.count <= 63,
                  let first = component.utf8.first, let last = component.utf8.last,
                  isASCIIAlphaNumeric(first), isASCIIAlphaNumeric(last) else { return false }
            return component.utf8.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 45 }
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// Shared deletion boundary used by classification and by the mutation service.
/// User Library is deny-by-default; only small, regenerable allowlisted zones are
/// available to ordinary Explorer deletion.
public enum DeletionSafetyPolicy {
    public static let currentHomeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    private static let protectedSystemTrees = [
        "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/dev", "/etc", "/var"
    ]
    private static let protectedHomeNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
        ".Trash", ".ssh", ".gnupg", ".aws", ".kube", ".config", ".docker",
        ".local", ".password-store", ".npmrc", ".netrc", ".git-credentials"
    ]
    private static let protectedHomeTreeNames: Set<String> = [
        ".Trash", ".ssh", ".gnupg", ".aws", ".kube", ".config", ".docker",
        ".local", ".password-store"
    ]
    private static let sensitivePackageMarkers = [
        ".photoslibrary", ".photolibrary", ".aplibrary", ".musiclibrary", ".imovielibrary",
        ".fcpbundle", ".vmwarevm", ".pvm", ".utm", ".sparsebundle", ".backupdb"
    ]

    public static func isProtectedForUserSelection(
        _ url: URL,
        isDirectory: Bool,
        homeURL: URL = currentHomeURL
    ) -> Bool {
        let path = url.standardizedFileURL.path
        return isProtectedPath(path, isDirectory: isDirectory, homePath: homeURL.standardizedFileURL.path)
    }

    private static func isProtectedPath(_ path: String, isDirectory: Bool, homePath: String) -> Bool {
        if isSystemTree(path) { return true }
        guard let home = homeRoot(containing: path, preferredHomePath: homePath) else {
            return path == "/Users" || path == "/Applications" || path == "/Volumes"
        }

        if path == home { return true }
        let relative = relativePath(path, under: home)
        if protectedHomeNames.contains(relative) { return true }
        if let firstComponent = relative.split(separator: "/", maxSplits: 1).first,
           protectedHomeTreeNames.contains(String(firstComponent)) { return true }
        if containsSensitivePackage(path) { return true }

        if relative == "Library" { return true }
        if relative.hasPrefix("Library/") {
            return !isSafeUserLibrarySelection(String(relative.dropFirst("Library/".count)), isDirectory: isDirectory)
        }
        return false
    }

    public static func safety(
        for url: URL,
        isDirectory: Bool,
        homeURL: URL = currentHomeURL
    ) -> SafetyLevel {
        // Scanner URLs are already absolute; normalize only suspicious dot-segment paths.
        let rawPath = url.path
        let path = rawPath.contains("/../") || rawPath.hasSuffix("/..") ? url.standardizedFileURL.path : rawPath
        let homePath = homeURL.path
        if isProtectedPath(path, isDirectory: isDirectory, homePath: homePath) { return .system }
        if path.contains("/Downloads/") || ["dmg", "pkg", "zip"].contains(url.pathExtension.lowercased()) {
            return .safeToReview
        }
        if isAllowlistedLibraryItem(path, homeURL: homeURL, isDirectory: isDirectory) { return .safeToReview }
        if path.contains("/Documents/") || path.contains("/Desktop/") || path.contains("/Pictures/") {
            return .personal
        }
        return isDirectory ? .review : .personal
    }

    /// Narrow exception for candidates proven to belong to one third-party bundle.
    /// Shared group containers, credentials, cloud data, Mail and Photos remain denied.
    public static func allowsVerifiedApplicationAssociation(
        _ url: URL,
        bundleIdentifier: String,
        isDirectory: Bool,
        homeURL: URL = currentHomeURL
    ) -> Bool {
        guard BundleIdentifierValidator.isValid(bundleIdentifier),
              !bundleIdentifier.lowercased().hasPrefix("com.apple.") else { return false }
        let path = url.standardizedFileURL.path
        guard !isSystemTree(path) else { return false }

        if url.pathExtension.lowercased() == "app", isDirectory,
           Bundle(url: url)?.bundleIdentifier == bundleIdentifier {
            return true
        }

        let library = homeURL.standardizedFileURL.appendingPathComponent("Library", isDirectory: true)
        let exactRelativePaths = [
            "Preferences/\(bundleIdentifier).plist",
            "Caches/\(bundleIdentifier)",
            "Logs/\(bundleIdentifier)",
            "Saved Application State/\(bundleIdentifier).savedState",
            "WebKit/\(bundleIdentifier)",
            "Cookies/\(bundleIdentifier).binarycookies",
            "HTTPStorages/\(bundleIdentifier)",
            "Application Support/\(bundleIdentifier)",
            "Containers/\(bundleIdentifier)",
            "Application Scripts/\(bundleIdentifier)"
        ]
        let approved = exactRelativePaths.compactMap { safeAppend(relativePath: $0, to: library) }
        if approved.contains(where: { $0.standardizedFileURL.path == path }) { return true }

        let byHost = library.appendingPathComponent("Preferences/ByHost", isDirectory: true).standardizedFileURL.path
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let name = url.lastPathComponent
        return parent == byHost
            && (name == bundleIdentifier + ".plist" || name.hasPrefix(bundleIdentifier + "."))
            && name.hasSuffix(".plist")
    }

    private static func isSystemTree(_ path: String) -> Bool {
        guard path == "/" || path.first == "/" else { return true }
        return protectedSystemTrees.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func homeRoot(containing path: String, preferredHomePath: String) -> String? {
        if path == preferredHomePath || path.hasPrefix(preferredHomePath + "/") { return preferredHomePath }
        let prefix = "/Users/"
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = path.dropFirst(prefix.count)
        let user = remainder.prefix { $0 != "/" }
        guard !user.isEmpty else { return nil }
        return prefix + String(user)
    }

    private static func relativePath(_ path: String, under root: String) -> String {
        guard path != root else { return "" }
        return String(path.dropFirst(root.count + 1))
    }

    private static func isSafeUserLibrarySelection(_ relative: String, isDirectory: Bool) -> Bool {
        if relative == "Logs/DiagnosticReports" { return false }
        let safeRoots = ["Caches", "Logs", "Developer/Xcode/DerivedData", "Developer/CoreSimulator/Caches"]
        guard let root = safeRoots.first(where: { relative.hasPrefix($0 + "/") }) else { return false }
        let remainder = String(relative.dropFirst(root.count + 1))
        guard !remainder.isEmpty else { return false }
        if root == "Caches" || root == "Logs" {
            let first = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if first.lowercased().hasPrefix("com.apple.") { return false }
        }
        if relative.hasPrefix("Logs/DiagnosticReports/") { return true }
        _ = isDirectory
        return true
    }

    private static func isAllowlistedLibraryItem(_ path: String, homeURL: URL, isDirectory: Bool) -> Bool {
        guard let home = homeRoot(containing: path, preferredHomePath: homeURL.path) else { return false }
        let relative = relativePath(path, under: home)
        guard relative.hasPrefix("Library/") else { return false }
        return isSafeUserLibrarySelection(String(relative.dropFirst("Library/".count)), isDirectory: isDirectory)
    }

    private static func containsSensitivePackage(_ path: String) -> Bool {
        let value = path.lowercased()
        return sensitivePackageMarkers.contains { marker in
            value.hasSuffix(marker) || value.contains(marker + "/")
        }
    }

    private static func safeAppend(relativePath: String, to root: URL) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return nil
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }
}
