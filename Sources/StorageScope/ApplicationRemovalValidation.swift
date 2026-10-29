import Foundation
import CoreServices
import Darwin
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
        let rootOwned = (try FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountID] as? NSNumber)?.intValue == 0
        guard let app = await ApplicationDiscoveryService().application(at: url), !app.isProtected,
              !rootOwned || app.eligibility == .authorizationRequired else { throw CocoaError(.fileReadCorruptFile) }
        if environment["STORAGESCOPE_QA_FINDER_ONLY"] == "1" {
            guard !rootOwned, let identity = app.bundleIdentity, let identifier = app.bundleIdentifier else { throw CocoaError(.fileReadNoPermission) }
            let request = ApplicationBundleRemovalRequest(url: url, bundleIdentifier: identifier, identity: identity)
            try SystemApplicationBundleRemover.validate(request)
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, FinderRecycleProtocol.eventClass, FinderRecycleProtocol.eventID, false)
            var record: [String: Any] = ["version": AppIdentity.version, "permissionCode": permission,
                "command": "core/delo", "consentWasNotModified": true, "actualFinderMoveVerified": false]
            if permission == noErr {
                let reply = try FinderRecycleProtocol.deleteEvent(for: url).sendEvent(options: [.waitForReply, .neverInteract], timeout: 15)
                let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
                guard code == 0, !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteUnknown) }
                let object = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
                var destination = FinderRecycleProtocol.fileURL(object)
                if destination == nil, let object = FinderRecycleProtocol.firstObject(object),
                   let query = FinderRecycleProtocol.urlPropertyEvent(for: object) {
                    let answer = try query.sendEvent(options: [.waitForReply, .neverInteract], timeout: 10)
                    destination = FinderRecycleProtocol.fileURL(answer.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
                }
                var metadata = stat()
                guard let destination, lstat(destination.path, &metadata) == 0,
                      FileIdentity.deviceID(fromRawValue: metadata.st_dev) == identity.deviceID,
                      UInt64(metadata.st_ino) == identity.inode else { throw CocoaError(.fileReadCorruptFile) }
                record["actualFinderMoveVerified"] = true
            } else {
                record["limitation"] = "Interactive Automation consent is unavailable on this runner; no event was sent and the fixture remains intact."
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            }
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to:
                URL(fileURLWithPath: output).appendingPathComponent("storagescope-application-removal-finder.json"))
            print("Finder protocol integration: \(record)")
            return
        }
        let service = UninstallService(), plan = await service.makePlan(for: app)
        guard plan.canProceed else { throw CocoaError(.fileWriteNoPermission) }
        let result = await service.uninstall(plan, selectedCandidateIDs: [])
        let record: [String: Any] = ["version": AppIdentity.version, "status": result.status.rawValue,
            "rootOwnedBundleSelectable": rootOwned && !app.isProtected, "rootOwned": rootOwned,
            "systemTrashVerified": result.status == .succeeded, "interactiveAuthorizationValidated": false,
            "resultingURL": result.bundleResult?.resultingURL?.path ?? "",
            "associatedDataUntouched": result.associatedResults.isEmpty,
            "message": result.message ?? "", "systemAPI": "NSWorkspace.recycle / FileManager.trashItem"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output).appendingPathComponent("storagescope-application-removal-\(rootOwned ? "root" : "user").json"))
        if rootOwned && environment["STORAGESCOPE_QA_EXPECT"] == "permission-boundary" && [.authorizationRequired, .authorizationDenied].contains(result.status) {
            guard FileManager.default.fileExists(atPath: url.path), result.associatedResults.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            print("PASS real root-owned bundle: system consent required, source and associated data preserved; interactive approval is a separate manual scenario")
            return
        }
        guard result.status == .succeeded, !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteNoPermission) }
        print("PASS actual installed application's system recycle of a root-owned disposable bundle")
    }
}
