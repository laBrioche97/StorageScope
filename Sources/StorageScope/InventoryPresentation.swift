import AppKit
import StorageCore

/// High-frequency inventory changes must not invalidate the scanner or explorer.
@MainActor
final class InventoryPresentation: ObservableObject {
    @Published var applications: [InstalledApplication] = []
    @Published var applicationsByName: [InstalledApplication] = []
    @Published var applicationsLargest: [InstalledApplication] = []
    @Published var applicationsSmallest: [InstalledApplication] = []
    @Published var gamesByName: [ManagedGame] = []
    @Published var gamesLargest: [ManagedGame] = []
    @Published var gamesSmallest: [ManagedGame] = []
    @Published var sizes: [String: InstallationSize] = [:]
    @Published var applicationIcons: [String: NSImage] = [:]
    @Published var gameIcons: [String: NSImage] = [:]
    @Published var revision = UUID()
}

struct ApplicationRowPresentation: Identifiable, Equatable, Sendable {
    var id: String { application.id }
    let application: InstalledApplication
    let size: String
    let source: String
    let permission: String

    init(application: InstalledApplication, size: InstallationSize) {
        self.application = application; self.size = size.label
        source = FileManager.default.fileExists(atPath: application.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt").path) ? "App Store" : "Application Mac"
        permission = switch application.eligibility {
        case .removable: "Désinstallable"
        case .authorizationRequired: "Autorisation macOS"
        case .officialUninstallerRequired: "Méthode officielle"
        case .blocked: "Protégée"
        }
    }
}
