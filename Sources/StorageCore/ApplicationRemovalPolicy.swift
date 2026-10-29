import Foundation

/// A declared updater helper does not imply a separate application uninstaller.
/// Known standalone browsers are removed by trashing their bundle; shared
/// updaters and profile data remain protected, exactly as in the review plan.
public enum ApplicationRemovalPolicy {
    private static let standaloneBrowsers: Set<String> = [
        "org.mozilla.firefox", "com.google.Chrome", "com.microsoft.edgemac"
    ]
    public static func requiresOfficialUninstaller(at url: URL, bundleIdentifier: String?, declaredHelpers: [String]) -> Bool {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Library/SystemExtensions").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Library/LaunchDaemons").path) { return true }
        return !declaredHelpers.isEmpty && !standaloneBrowsers.contains(bundleIdentifier ?? "")
    }
}
