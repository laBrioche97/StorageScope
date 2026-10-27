import AppKit
import Sparkle
import StorageCore

@MainActor
enum PackagedValidation {
    static var updateFeed: String? {
        guard ProcessInfo.processInfo.environment["STORAGESCOPE_ISOLATED_VALIDATION"] == "1" else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "StorageScopeValidationFeedURL") as? String
    }
    static func recordUpdate(_ phase: String) {
        guard ProcessInfo.processInfo.environment["STORAGESCOPE_ISOLATED_VALIDATION"] == "1",
              let path = ProcessInfo.processInfo.environment["STORAGESCOPE_UPDATE_VALIDATION_RESULT"] else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { _ = FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data((phase + "\n").utf8))
        }
    }
    static func run() throws {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "com.labrioche.StorageScope",
              bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "14.0",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: key)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              let icon = bundle.url(forResource: "StorageScope", withExtension: "icns"), NSImage(contentsOf: icon) != nil,
              bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil,
              bundle.privateFrameworksURL.map({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("Sparkle.framework").path) }) == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for asset in ["classic-library", "classic-menu", "new-library", "new-game"] {
            guard let url = EpicGuideResources.bundle.url(forResource: asset, withExtension: "png", subdirectory: "EpicGuide"), NSImage(contentsOf: url) != nil else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        print("Packaged installation verified offline: \(AppIdentity.title), Sparkle, icon, privacy manifest and offline guide")
    }
}
