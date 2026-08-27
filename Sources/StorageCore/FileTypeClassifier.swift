import Foundation
import UniformTypeIdentifiers

public enum FileTypeClassifier {
    private static let videos: Set<String> = ["3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "webm", "wmv"]
    private static let images: Set<String> = ["arw", "avif", "bmp", "cr2", "dng", "gif", "heic", "heif", "ico", "jpeg", "jpg", "nef", "png", "psd", "raw", "svg", "tif", "tiff", "webp"]
    private static let archives: Set<String> = ["7z", "bz2", "cab", "dmg", "gz", "img", "iso", "pkg", "rar", "tar", "tgz", "xz", "zip"]
    private static let documents: Set<String> = ["csv", "doc", "docx", "epub", "key", "md", "numbers", "odf", "ods", "odt", "pages", "pdf", "ppt", "pptx", "rtf", "tex", "txt", "xls", "xlsx"]
    private static let audio: Set<String> = ["aac", "aif", "aiff", "alac", "flac", "m4a", "mid", "midi", "mp3", "ogg", "opus", "wav", "wma"]
    private static let developmentExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "dart", "ex", "go", "gradle", "h", "hpp", "html", "java", "js", "json", "jsx", "kt", "kts", "lua", "m", "mm", "php", "plist", "py", "rb", "rs", "scss", "sh", "sql", "swift", "toml", "ts", "tsx", "vue", "xml", "yaml", "yml"
    ]
    private static let backupExtensions: Set<String> = ["bak", "backup", "bkf", "old", "orig", "tmbackup"]
    private static let mailExtensions: Set<String> = ["eml", "emlx", "mbox"]
    private static let cacheAndLogExtensions: Set<String> = ["cache", "crash", "ips", "log", "trace"]
    private static let virtualMachineExtensions: Set<String> = ["hdd", "pvm", "qcow", "qcow2", "utm", "vbox", "vdi", "vhd", "vhdx", "vmdk", "vmwarevm"]
    private static let photoLibraryExtensions: Set<String> = ["aplibrary", "migratedphotolibrary", "photolibrary", "photoslibrary"]
    private static let developmentContainerExtensions: Set<String> = ["playground", "xcodeproj", "xcworkspace"]

    /// `inheritedContainerCategory` lets the scanner propagate package ownership without
    /// repeatedly parsing every ancestor. Other callers retain full ancestor detection.
    public static func category(
        for url: URL,
        isDirectory: Bool,
        isPackage: Bool,
        inheritedContainerCategory: ItemCategory? = nil,
        inspectAncestorContainers: Bool = true
    ) -> ItemCategory {
        if let ownContainer = containerCategory(for: url, isDirectory: isDirectory, isPackage: isPackage) {
            return ownContainer
        }
        if let inheritedContainerCategory { return inheritedContainerCategory }
        if inspectAncestorContainers, let ancestor = ancestorContainerCategory(for: url) { return ancestor }
        if let pathCategory = categoryForKnownPath(url.path) { return pathCategory }

        let ext = url.pathExtension.lowercased()
        if virtualMachineExtensions.contains(ext) { return .virtualMachine }
        if videos.contains(ext) { return .video }
        if images.contains(ext) { return .image }
        if archives.contains(ext) { return .archive }
        if documents.contains(ext) { return .document }
        if audio.contains(ext) { return .audio }
        if developmentExtensions.contains(ext) { return .development }
        if backupExtensions.contains(ext) { return .backup }
        if mailExtensions.contains(ext) { return .mailAndMessages }
        if cacheAndLogExtensions.contains(ext) { return .cacheAndLogs }
        guard !ext.isEmpty else { return .other }
        return extensionTypeCache.category(for: ext)
    }

    /// Categories whose contents inherit the container's category.
    static func containerCategory(for url: URL, isDirectory: Bool, isPackage: Bool) -> ItemCategory? {
        let ext = url.pathExtension.lowercased()
        if ext == "app" { return .application }
        if photoLibraryExtensions.contains(ext) { return .image }
        if virtualMachineExtensions.contains(ext) { return .virtualMachine }
        if isDirectory && developmentContainerExtensions.contains(ext) { return .development }
        // Some file providers fail to set isPackage. Recognized extensions above remain
        // authoritative; unknown packages intentionally fall through to path/type rules.
        _ = isPackage
        return nil
    }

    public static func safety(for url: URL, isDirectory: Bool) -> SafetyLevel {
        DeletionSafetyPolicy.safety(
            for: url, isDirectory: isDirectory,
            homeURL: DeletionSafetyPolicy.currentHomeURL
        )
    }

    private static func ancestorContainerCategory(for url: URL) -> ItemCategory? {
        // Walk nearest-first so a nested package wins. This slower fallback is used by
        // ad-hoc callers; StorageScanner supplies its inherited package category directly.
        let components = url.deletingLastPathComponent().pathComponents
        for component in components.reversed() {
            let ext = (component as NSString).pathExtension.lowercased()
            if ext == "app" { return .application }
            if photoLibraryExtensions.contains(ext) { return .image }
            if virtualMachineExtensions.contains(ext) { return .virtualMachine }
            if developmentContainerExtensions.contains(ext) { return .development }
        }
        return nil
    }

    private static func categoryForKnownPath(_ path: String) -> ItemCategory? {
        let value = path.lowercased()

        if containsAny(value, [
            "/library/mail/", "/library/messages/", "/library/chat/", "/mail/v", "/messages/attachments/"
        ]) { return .mailAndMessages }

        if containsAny(value, [
            "/mobilesync/backup/", "/backups.backupdb/", "/mobilebackups/", "/library/application support/mobilesync/backup/", "/time machine backups/"
        ]) { return .backup }

        if containsAny(value, [
            "/library/caches/", "/library/logs/", "/var/log/", "/var/folders/", "/diagnosticreports/", "/crashreporter/"
        ]) { return .cacheAndLogs }

        if containsAny(value, [
            "/developer/", "/deriveddata/", "/coresimulator/", "/simulators/", "/node_modules/", "/.npm/", "/.pnpm/", "/.yarn/", "/.gradle/", "/.cocoapods/", "/.swiftpm/", "/homebrew/", "/cellar/", "/docker/", "/containers/com.docker."
        ]) || value.hasSuffix("/node_modules") || value.hasSuffix("/deriveddata") { return .development }

        if containsAny(value, [
            "/virtual machines/", "/virtualbox vms/", "/parallels/", "/utm/"
        ]) { return .virtualMachine }

        if containsAny(value, [
            "/library/application support/", "/library/containers/", "/library/group containers/", "/library/preferences/", "/library/saved application state/", "/library/webkit/"
        ]) { return .applicationData }

        if value == "/system" || value.hasPrefix("/system/") || value == "/usr" || value.hasPrefix("/usr/") || value == "/bin" || value.hasPrefix("/bin/") || value == "/sbin" || value.hasPrefix("/sbin/") || value == "/library" || value.hasPrefix("/library/") || isUserLibraryPath(value) || value.hasPrefix("/private/var/db/") {
            return .systemAndLibrary
        }
        return nil
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private static func isUserLibraryPath(_ value: String) -> Bool {
        let prefix = "/users/"
        guard value.hasPrefix(prefix) else { return false }
        let afterPrefix = value.dropFirst(prefix.count)
        guard let userSeparator = afterPrefix.firstIndex(of: "/") else { return false }
        let afterUser = afterPrefix[afterPrefix.index(after: userSeparator)...]
        return afterUser == "library" || afterUser.hasPrefix("library/")
    }

    private static let extensionTypeCache = ExtensionTypeCache()
}

private final class ExtensionTypeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ItemCategory] = [:]

    func category(for fileExtension: String) -> ItemCategory {
        if let cached = lock.withLock({ values[fileExtension] }) { return cached }
        let result = classify(fileExtension)
        lock.withLock { values[fileExtension] = result }
        return result
    }

    private func classify(_ fileExtension: String) -> ItemCategory {
        guard let type = UTType(filenameExtension: fileExtension) else { return .other }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) { return .development }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation) { return .document }
        return .other
    }
}
