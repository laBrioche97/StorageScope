import CoreServices
import Foundation
import StorageCore

func awaitSynchronizedTree(root: URL, volumeID: String, expectedLogicalBytes: Int64? = nil) async throws -> TreeIndexState {
    try await withThrowingTaskGroup(of: TreeIndexState.self) { group in
        group.addTask {
            for await event in PersistentScanSynchronizer.synchronize(root: root, volumeID: volumeID, observeChanges: { batch in
                if ProcessInfo.processInfo.environment["STORAGESCOPE_INDEX_UPGRADE_FIXTURE"] != nil {
                    print("REPLAY source=\(batch.source), count=\(batch.changes.count), first=\(batch.changes.prefix(8).map { "\($0.id):\($0.flags):\($0.path)" })")
                }
            }) {
                switch event {
                case .updated(let state, settled: true):
                    if ProcessInfo.processInfo.environment["STORAGESCOPE_INDEX_UPGRADE_FIXTURE"] != nil { print("REPLAY files=\(state.snapshot.progress.filesScanned), bytes=\(state.snapshot.categoryReport.identifiedLogicalBytes), pending=\(state.pending.count), issues=\(state.snapshot.issues.prefix(3).map(\.message))") }
                    if expectedLogicalBytes == nil || state.snapshot.categoryReport.identifiedLogicalBytes == expectedLogicalBytes { return state }
                case .status(.requiresScan, let message): throw ValidationError.failed(message)
                default: break
                }
            }
            throw ValidationError.failed("Le journal s’est fermé avant la fin de la reprise")
        }
        group.addTask { try await Task.sleep(for: .seconds(25)); throw ValidationError.failed("Le journal macOS n’a pas rattrapé les changements en 25 secondes") }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func testPersistentTreeAndJournal() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".StorageScope-Tree-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("Before/deep", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = root.lastPathComponent
    let database = try DirectoryIndexStore.defaultDatabaseURL(for: volume, root: root)
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) } }
    for index in 0..<2305 { try Data([1]).write(to: nested.appendingPathComponent("small-\(index).txt")) }
    let changed = root.appendingPathComponent("changed.dat")
    try Data([1]).write(to: changed)
    var completed: ScanSnapshot?
    for await event in StorageScanner(topFileLimit: 3, topDirectoryLimit: 2).scan(root: root, volumeID: volume) {
        if case .completed(let snapshot) = event { completed = snapshot }
    }
    try expect(completed?.progress.filesScanned == 2306, "Le scan conserve les fichiers admissibles au-delà des limites de présentation")
    try expect(completed?.topFiles.count == 3, "La taille du récapitulatif reste indépendante de l’index complet")
    let reopened = try DirectoryIndexStore(volumeID: volume, root: root)
    let children = try await reopened.indexedChildren(of: nested)
    try expect(children?.count == 2305 && children?.allSatisfy { $0.indexedIdentity != nil } == true, "Une nouvelle instance doit retrouver tous les petits fichiers et leur identité")
    let baseline = try await reopened.treeState()
    try expect(baseline?.checkpoint?.sources.contains(where: { $0.cursor > 0 }) == true, "Le repère FSEvents du volume de test actif doit utiliser l’époque Unix, pas une date de 1995")
    try expect(baseline?.snapshot.progress.filesScanned == 2306 && baseline?.checkpoint != nil, "Le résumé et le repère du journal sont persistants")
    let temporary = UUID()
    try await reopened.beginTreeGeneration(temporary)
    try await reopened.appendTreeItems([FileSystemItem(url: root.appendingPathComponent("uncommitted"), logicalSize: 100, allocatedSize: 100, isDirectory: false)], generation: temporary)
    let stillComplete = try await reopened.indexedChildren(of: nested)
    try expect(stillComplete?.count == 2305, "Un scan temporaire ou annulé ne remplace pas la génération active")

    let superseding = UUID()
    try await reopened.beginTreeGeneration(superseding)
    var staleWriterRejected = false
    do { try await reopened.appendTreeItems([FileSystemItem(url: root.appendingPathComponent("late-write"), logicalSize: 1, allocatedSize: 1, isDirectory: false)], generation: temporary) }
    catch { staleWriterRejected = true }
    try expect(staleWriterRejected, "Une tâche remplacée ne doit plus pouvoir écrire dans l’index")

    // Changes while no stream is running must be replayed on the next launch.
    try Data(repeating: 7, count: 9000).write(to: changed)
    try FileManager.default.removeItem(at: nested.appendingPathComponent("small-0.txt"))
    let renamed = root.appendingPathComponent("After", isDirectory: true)
    try FileManager.default.moveItem(at: root.appendingPathComponent("Before"), to: renamed)
    let added = root.appendingPathComponent("Added/child", isDirectory: true)
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    try Data([2, 3, 4]).write(to: added.appendingPathComponent("new.bin"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
    let synchronized = try await awaitSynchronizedTree(root: root, volumeID: volume, expectedLogicalBytes: 2304 + 9000 + 3)
    let final = try await reopened.indexedChildren(of: renamed.appendingPathComponent("deep"))
    let missing = try await reopened.indexedChildren(of: nested)
    let top = try await reopened.indexedChildren(of: root)
    try expect(final?.count == 2304 && missing?.isEmpty == true, "Un dossier renommé doit déplacer toute l’arborescence sans conserver les anciens descendants (nouveau=\(final?.count ?? -1), ancien=\(missing?.count ?? -1), racine=\(top?.map(\.name) ?? []))")
    try expect(top?.first(where: { $0.name == "changed.dat" })?.logicalSize == 9000, "La taille d’un fichier modifié doit être actualisée")
    try expect(top?.contains(where: { $0.name == "loop" }) == false, "La reprise du journal ne traverse pas de lien")
    try expect(synchronized.snapshot.progress.filesScanned == 2306 && synchronized.pending.isEmpty && synchronized.snapshot.issues.isEmpty, "La réconciliation garde des compteurs exacts et termine sans faux état partiel")
    let reopenedWithoutChanges = try await awaitSynchronizedTree(root: root, volumeID: volume)
    try expect(reopenedWithoutChanges.snapshot.progress.filesScanned == synchronized.snapshot.progress.filesScanned, "Une ouverture sans changement doit terminer la vérification sans attendre un événement")
    let report = synchronized.snapshot.categoryReport
    try expect(report.identifiedLogicalBytes == 2304 + 9000 + 3, "Les totaux et les catégories doivent être recalculés depuis l’index complet")
    let rootSummary = try await reopened.summary(forPath: root.path)
    try expect(rootSummary?.logicalSize == report.identifiedLogicalBytes, "Les tailles des parents suivent les changements des descendants")

    guard let indexed = top?.first(where: { $0.name == "changed.dat" }) else { throw ValidationError.failed("Fichier absent") }
    guard let identity = ScanPathPolicy.identity(changed), let uuid = try changed.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { throw ValidationError.failed("Le volume APFS du test doit avoir un UUID persistant") }
    let rebooted = FileSystemItem(url: changed, logicalSize: 9000, allocatedSize: 9000, isDirectory: false, indexedIdentity: FileIdentity(deviceID: identity.deviceID ^ 1, inode: identity.inode, fileType: identity.fileType), indexedVolumeUUID: uuid)
    let rebootCheck = await TrashService().preflight([rebooted])
    try expect(rebootCheck.first?.isReady == true, "Un nouvel identifiant de montage après redémarrage ne change pas l’identité du fichier sur le même UUID")
    let wrongVolume = FileSystemItem(url: changed, logicalSize: 9000, allocatedSize: 9000, isDirectory: false, indexedIdentity: identity, indexedVolumeUUID: "another-volume")
    let wrongVolumeCheck = await TrashService().preflight([wrongVolume])
    try expect(wrongVolumeCheck.first?.isReady == false, "Un numéro de périphérique réutilisé ne prouve pas que le volume est le même")
    // Retain the original inode so the replacement cannot accidentally reuse it.
    try FileManager.default.moveItem(at: changed, to: root.appendingPathComponent("old-inode.dat"))
    try Data([9]).write(to: changed)
    let preflight = await TrashService().preflight([indexed])
    try expect(preflight.first?.isReady == false, "Un fichier remplacé depuis l’index doit être bloqué avant confirmation")
}

func testJournalPlanningAndIdentity() throws {
    let source = JournalSource(device: 1, uuid: "journal-a", mountPath: "/", watchPath: "/Users/example", cursor: 50)
    let checkpoint = JournalCheckpoint(rootFingerprint: "disk:snapshot-a", sources: [source])
    let reassigned = JournalSource(device: 99, uuid: source.uuid, mountPath: source.mountPath, watchPath: source.watchPath, cursor: 51)
    try expect(checkpoint.matches(JournalCheckpoint(rootFingerprint: checkpoint.rootFingerprint, sources: [reassigned])), "Un nouveau dev_t n’invalide pas le journal du même volume")
    let rewound = JournalSource(device: 99, uuid: source.uuid, mountPath: source.mountPath, watchPath: source.watchPath, cursor: 49)
    try expect(checkpoint.matches(JournalCheckpoint(rootFingerprint: checkpoint.rootFingerprint, sources: [rewound])), "Le repère temporel conservateur n’est pas le dernier événement du journal ; une valeur plus basse ne prouve pas sa perte")
    let sentinel = JournalSource(device: 99, uuid: source.uuid, mountPath: source.mountPath, watchPath: source.watchPath, cursor: UInt64.max)
    try expect(!checkpoint.matches(JournalCheckpoint(rootFingerprint: checkpoint.rootFingerprint, sources: [sentinel])), "La sentinelle depuis maintenant ne constitue pas un curseur persistant")
    try expect(JournalCheckpoint.stableFingerprint(volumeUUID: "persistent-volume") == "persistent-volume", "L’empreinte des données ne doit pas contenir de numéro de disque temporaire")
    try expect(JournalCheckpoint.stableFingerprint(volumeUUID: "system", systemBuild: "build-a") != JournalCheckpoint.stableFingerprint(volumeUUID: "system", systemBuild: "build-b"), "Un nouveau système scellé exige une nouvelle analyse")
    let changedDisk = JournalCheckpoint(rootFingerprint: "disk:snapshot-b", sources: [source])
    try expect(!checkpoint.matches(changedDisk), "Un nouveau snapshot système exige une nouvelle base fiable")
    let root = URL(fileURLWithPath: "/Users/example")
    let flags = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
    let batch = JournalBatch(source: 0, changes: [JournalChange(path: "Users/example/docs/a.txt", flags: flags, id: 51), JournalChange(path: "Users/example/docs/b.txt", flags: flags, id: 52)])
    let replacements = try PersistentScanSynchronizer.replacements(for: batch, checkpoint: checkpoint, root: root)
    try expect(replacements.count == 1 && replacements[0].directory.path == "/Users/example/docs" && !replacements[0].recursive, "Deux fichiers voisins ne doivent pas relancer une analyse récursive du stockage")
    let coalesced = PersistentScanSynchronizer.coalesce([TreeReplacement(directory: root, recursive: true), TreeReplacement(directory: root.appendingPathComponent("child"), recursive: false)])
    try expect(coalesced.count == 1, "Un sous-arbre ne doit pas être relu plusieurs fois")
}
