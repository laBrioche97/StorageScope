import Foundation
import StorageCore

/// Real destructive checks are restricted to uniquely named disposable CI data.
@MainActor enum ExplorerTrashValidation {
    static func run(model: AppModel) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let output = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { throw CocoaError(.userCancelled) }
        let manager = FileManager.default
        let fixture = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StorageScope-QA-" + UUID().uuidString, isDirectory: true)
        let target = fixture.appendingPathComponent("TabNine", isDirectory: true)
        let locked = target.appendingPathComponent("locked", isDirectory: true)
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("Disposable CI fixture".utf8).write(to: locked.appendingPathComponent("model.bin"))
        var trashed: URL?
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: (trashed?.appendingPathComponent("locked") ?? locked).path)
            try? manager.removeItem(at: fixture)
        }
        let item = FileSystemItem(url: target, logicalSize: 4096, allocatedSize: 4096,
            isDirectory: true, category: .applicationData, safety: .system)
        let service = TrashService()
        let ordinary = await service.preflight([item])
        guard ordinary.first?.isReady == false else { throw failure("Application data became automatically removable") }
        let prepared = await service.preflight([item], authorization: .manualApplicationData)
        guard let expected = prepared.first?.identity, prepared.first?.isReady == true else { throw failure("Manual TabNine review was blocked") }
        model.requestTrash(items: [item])
        let deadline = Date().addingTimeInterval(10)
        while !model.showingTrashConfirmation && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard model.showingTrashConfirmation, model.trashConfirmationMessage.contains("réglages"),
              model.trashConfirmationMessage.contains(target.path), manager.fileExists(atPath: target.path) else {
            throw failure("The real Explorer action did not explain application data before deletion: \(model.alertMessage ?? "")")
        }
        // A child that cannot be read must not make the whole trash entry disappear.
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        model.confirmTrash()
        while model.trashIsWorking && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !model.trashIsWorking, !manager.fileExists(atPath: target.path) else {
            throw failure("Confirmed system recycle failed: \(model.alertMessage ?? "")")
        }
        let inventory = await service.inventoryTrash()
        guard let entry = inventory.items.first(where: { $0.identity == expected }) else { throw failure("Unreadable trash entry disappeared") }
        trashed = entry.url
        guard !entry.sizeIsComplete, inventory.isPartial else { throw failure("Unreadable subtree was reported as completely measured") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.url.appendingPathComponent("locked").path)
        // Only this identity-checked fixture is ever authorized for permanent removal.
        let reviewed = TrashInventory(items: [entry], issues: inventory.issues)
        let result = await service.emptyTrash(reviewed, authorization: .confirm(reviewed))
        guard result.itemResults.count == 1, result.itemResults[0].status == .deleted,
              result.inventoryWasPartial, !manager.fileExists(atPath: entry.url.path) else { throw failure("Fixture-only empty trash failed") }

        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("old.bin"))
        let stale = await service.preflight([item], authorization: .manualApplicationData)
        let saved = fixture.appendingPathComponent("saved")
        try manager.moveItem(at: target, to: saved)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: target.appendingPathComponent("new.bin"))
        let rejected = await service.trashWithResults(stale)
        guard rejected.first?.status == .failed, manager.fileExists(atPath: target.appendingPathComponent("new.bin").path),
              manager.fileExists(atPath: saved.appendingPathComponent("old.bin").path) else { throw failure("A replaced folder was deleted") }
        let record: [String: Any] = ["version": AppIdentity.version, "realExplorerConfirmation": true,
            "ordinaryCleanupRemainsBlocked": true, "actualSystemRecycle": true,
            "unreadableTrashEntryRetained": true, "unknownSizeNotZero": true,
            "onlyDisposableFixtureEmptied": true, "replacedFolderPreserved": true]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("storagescope-explorer-trash-validation.json"))
        print("PASS real manual application-data confirmation, recycle, partial inventory, fixture-only empty and replacement protection")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "StorageScope.ExplorerTrashValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
