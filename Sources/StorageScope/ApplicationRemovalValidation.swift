import Foundation
import StorageCore

/// Explicit installed-app integration check. Only a marked disposable CI fixture
/// under /Applications is accepted; normal startup never enters this code.
@MainActor enum ApplicationRemovalValidation {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", let path = environment["STORAGESCOPE_QA_ROOT_APP"],
              let output = environment["RUNNER_TEMP"] else { throw CocoaError(.userCancelled) }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.deletingLastPathComponent().path == "/Applications", url.lastPathComponent.hasPrefix("StorageScope-QA-"),
              Bundle(url: url)?.bundleIdentifier == "com.labrioche.permission-fixture",
              try String(contentsOf: url.appendingPathComponent("Contents/Resources/StorageScope-QA-marker"), encoding: .utf8) == "Disposable CI fixture" else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard let app = await ApplicationDiscoveryService().application(at: url), app.eligibility == .authorizationRequired,
              !app.isProtected else { throw CocoaError(.fileReadCorruptFile) }
        let service = UninstallService(), plan = await service.makePlan(for: app)
        guard plan.canProceed else { throw CocoaError(.fileWriteNoPermission) }
        let result = await service.uninstall(plan, selectedCandidateIDs: [])
        let record: [String: Any] = ["version": AppIdentity.version, "status": result.status.rawValue,
            "rootOwnedBundleSelectable": true, "resultingURL": result.bundleResult?.resultingURL?.path ?? "",
            "associatedDataUntouched": result.associatedResults.isEmpty,
            "message": result.message ?? "", "systemAPI": "NSWorkspace.recycle / FileManager.trashItem"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output).appendingPathComponent("storagescope-application-removal-validation.json"))
        guard result.status == .succeeded, !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteNoPermission) }
        print("PASS actual installed application's system recycle of a root-owned disposable bundle")
    }
}
