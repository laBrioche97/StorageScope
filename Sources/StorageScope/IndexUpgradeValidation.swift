import AppKit
import Foundation
import StorageCore

/// Installed-app check on an ephemeral runner. Nothing in a real user's disk is scanned.
@MainActor enum IndexUpgradeValidation {
    struct Fixture: Codable {
        let root: URL
        let volumeID: String
        let scanID: UUID
        let completedAt: Date
        let generation: UUID
        let database: URL
    }
    static func run(model: AppModel, prepare: Bool) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let path = ProcessInfo.processInfo.environment["STORAGESCOPE_INDEX_UPGRADE_FIXTURE"] else { throw CocoaError(.featureUnsupported) }
        let manifest = URL(fileURLWithPath: path)
        if prepare {
            let root = ScanPathPolicy.physicalURL(manifest.deletingLastPathComponent().appendingPathComponent("index-upgrade-" + UUID().uuidString, isDirectory: true))
            let nested = root.appendingPathComponent("Documents/deep", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            for index in 0..<2305 { try Data([1]).write(to: nested.appendingPathComponent("file-\(index).txt")) }
            let volumeID = root.lastPathComponent
            var complete: ScanSnapshot?
            for await event in StorageScanner(topFileLimit: 3, topDirectoryLimit: 2).scan(root: root, volumeID: volumeID) {
                if case .completed(let snapshot) = event { complete = snapshot }
            }
            let store = try DirectoryIndexStore(volumeID: volumeID, root: root)
            guard let state = try await store.treeState(), let completedAt = complete?.completedAt,
                  complete?.progress.filesScanned == 2305 else { throw CocoaError(.fileReadCorruptFile) }
            try await ScanCache().save(state.snapshot)
            let fixture = Fixture(root: root, volumeID: volumeID, scanID: state.snapshot.scanID,
                completedAt: completedAt, generation: state.generation, database: store.databaseURL)
            try JSONEncoder().encode(fixture).write(to: manifest, options: .atomic)
            print("PASS durable schema-2 index prepared before replacing the published application")
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: manifest))
        let store = try DirectoryIndexStore(volumeID: fixture.volumeID, root: fixture.root)
        guard store.databaseURL == fixture.database, let before = try await store.treeState(),
              before.snapshot.scanID == fixture.scanID, before.generation == fixture.generation,
              before.snapshot.completedAt == fixture.completedAt,
              try await store.indexedChildren(of: fixture.root.appendingPathComponent("Documents/deep"))?.count == 2305 else { throw CocoaError(.fileReadCorruptFile) }
        model.volumes = [StorageVolume(id: fixture.volumeID, url: fixture.root, name: "Upgrade fixture", capacity: 100000, available: 50000, isLocal: true, isInternal: true)]
        model.selectedVolumeID = fixture.volumeID; model.snapshot = nil
        await model.restoreLastScan()
        guard model.snapshot?.scanID == fixture.scanID, !model.isScanning else { throw CocoaError(.fileReadCorruptFile) }
        model.sidebar = .explorer
        model.loadExplorerDirectory(fixture.root.appendingPathComponent("Documents/deep"))
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && (model.indexFreshness != .current || model.snapshot?.progress.filesScanned != 2306 || model.explorerIsLoading) {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard !model.isScanning, model.snapshot?.scanID == fixture.scanID,
              model.snapshot?.completedAt == fixture.completedAt,
              model.indexFreshness == .current, model.snapshot?.progress.filesScanned == 2306,
              try await store.indexedChildren(of: fixture.root)?.contains(where: { $0.name == "added-between-versions.bin" }) == true else { throw CocoaError(.fileReadCorruptFile) }
        // A folder created after the baseline has no measured summary. Opening it
        // must not turn a preserved disk index into a new full scan.
        let fresh = fixture.root.appendingPathComponent("just-created", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        model.loadExplorerDirectory(fresh)
        try await Task.sleep(for: .milliseconds(500))
        guard !model.isScanning, model.snapshot?.scanID == fixture.scanID else { throw CocoaError(.fileReadCorruptFile) }
        let report: [String: Any] = ["version": AppIdentity.version, "completeTreePreserved": true,
            "originalScanIDPreserved": true, "originalScanDatePreserved": true,
            "incrementalChangesApplied": true, "noAutomaticFullRescan": true, "filesBeyondOverviewLimit": 2305]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: manifest.deletingLastPathComponent().appendingPathComponent("index-upgrade-result.json"))
        print("PASS installed upgrade preserves complete index and updates only journal changes")
    }
}
