import Foundation
import StorageCore

private struct RestartFixture: Codable {
    let root: URL
    let volumeID: String
    let scanID: UUID
    let completedAt: Date
    let generation: UUID
}

func validatePersistentRestart(prepare: Bool) async throws {
    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
          let path = ProcessInfo.processInfo.environment["STORAGESCOPE_INDEX_UPGRADE_FIXTURE"] else { throw ValidationError.failed("Isolated CI only") }
    let manifest = URL(fileURLWithPath: path)
    if prepare {
        let root = manifest.deletingLastPathComponent().appendingPathComponent("restart-" + UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("Documents/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<2305 { try Data([1]).write(to: nested.appendingPathComponent("file-\(index).txt")) }
        let volumeID = root.lastPathComponent
        for await event in StorageScanner(topFileLimit: 3).scan(root: root, volumeID: volumeID) {
            if case .completed(let snapshot) = event {
                let store = try DirectoryIndexStore(volumeID: volumeID, root: root)
                guard let state = try await store.treeState(), let completedAt = snapshot.completedAt else { throw ValidationError.failed("No saved index") }
                let fixture = RestartFixture(root: root, volumeID: volumeID, scanID: snapshot.scanID, completedAt: completedAt, generation: state.generation)
                try JSONEncoder().encode(fixture).write(to: manifest)
                print("PASS index persisted by first process: \(root.path), \(String(describing: state.checkpoint))")
                return
            }
        }
        throw ValidationError.failed("The first process did not complete its scan")
    }
    let fixture = try JSONDecoder().decode(RestartFixture.self, from: Data(contentsOf: manifest))
    let store = try DirectoryIndexStore(volumeID: fixture.volumeID, root: fixture.root)
    let before = try await store.treeState()
    try expect(before?.generation == fixture.generation && before?.snapshot.scanID == fixture.scanID, "The index must survive termination of its writer")
    let state = try await awaitSynchronizedTree(root: fixture.root, volumeID: fixture.volumeID, expectedLogicalBytes: 2306)
    try expect(state.snapshot.scanID == fixture.scanID && state.snapshot.completedAt == fixture.completedAt && state.generation == fixture.generation,
        "Only incremental changes are applied, without replacing the original completed scan")
    try expect(state.snapshot.progress.filesScanned == 2306, "The new process must recover the file written between sessions")
    print("PASS full index restored and historical changes applied by a new process")
}
