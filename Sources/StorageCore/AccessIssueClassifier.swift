import Foundation

public enum AccessIssueCategory: String, CaseIterable, Sendable {
    case privacy = "Données utilisateur protégées"
    case system = "Protection système macOS"
    case transient = "Fichier disparu ou indisponible"
    case other = "Autre erreur"
}

public enum AccessIssueClassifier {
    public static func category(
        for issue: ScanIssue,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AccessIssueCategory {
        let path = issue.path
        let message = issue.message.lowercased()

        if !issue.isPermissionError {
            if message.contains("no such file") || message.contains("n’existe") || message.contains("not found") || message.contains("introuvable") {
                return .transient
            }
            return .other
        }

        let homePath = homeURL.standardizedFileURL.path
        if path == homePath || path.hasPrefix(homePath + "/") {
            return .privacy
        }

        let systemPrefixes = [
            "/System", "/private", "/Library", "/usr", "/bin", "/sbin",
            "/dev", "/cores", "/.Spotlight-V100", "/.fseventsd", "/Users"
        ]
        if systemPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .system
        }
        return .other
    }
}
