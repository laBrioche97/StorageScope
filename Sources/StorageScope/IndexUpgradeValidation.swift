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
        print("REPLAY baseline: root=\(fixture.root.path), checkpoint=\(String(describing: before.checkpoint)), newFileExists=\(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("added-between-versions.bin").path))")
        // Check the updater's durable data independently of mounted-volume UI
        // discovery: the disposable subdirectory is not a real mounted disk.
        // Actual AppModel restoration/navigation is covered by the installed
        // WindowGroup performance/interaction check after discovery has settled.
        let state = try await withThrowingTaskGroup(of: TreeIndexState.self) { group in
            group.addTask {
                for await event in PersistentScanSynchronizer.synchronize(root: fixture.root, volumeID: fixture.volumeID, observeChanges: { batch in
                    print("REPLAY batch source=\(batch.source): \(batch.changes.prefix(8).map { "\($0.id):\($0.flags):\($0.path)" })")
                }) {
                    switch event {
                    case .updated(let state, let settled):
                        print("REPLAY state: files=\(state.snapshot.progress.filesScanned), settled=\(settled), pending=\(state.pending.count), issues=\(state.snapshot.issues.prefix(3).map(\.message))")
                        if settled && state.snapshot.progress.filesScanned == 2306 { return state }
                    case .status(.requiresScan, let message):
                        throw NSError(domain: "StorageScope.IndexUpgrade", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    case .status(_, let message): print("REPLAY status: \(message)")
                    }
                }
                throw CocoaError(.fileReadUnknown)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw NSError(domain: "StorageScope.IndexUpgrade", code: 2, userInfo: [NSLocalizedDescriptionKey: "Le journal n’a pas repris le fichier ajouté entre versions."])
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard state.snapshot.scanID == fixture.scanID, state.generation == fixture.generation,
              state.snapshot.completedAt == fixture.completedAt,
              try await store.indexedChildren(of: fixture.root)?.contains(where: { $0.name == "added-between-versions.bin" }) == true else { throw CocoaError(.fileReadCorruptFile) }
        let report: [String: Any] = ["version": AppIdentity.version, "completeTreePreserved": true,
            "originalScanIDPreserved": true, "originalScanDatePreserved": true,
            "incrementalChangesApplied": true, "noAutomaticFullRescan": true, "filesBeyondOverviewLimit": 2305]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: manifest.deletingLastPathComponent().appendingPathComponent("index-upgrade-result.json"))
        print("PASS installed upgrade preserves complete index and updates only journal changes")
    }
}
