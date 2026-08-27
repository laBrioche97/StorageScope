import Foundation
import StorageCore

enum ValidationError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationError.failed(message) }
}

func testAggregation() throws {
    let root = URL(fileURLWithPath: "/tmp/StorageScopeTests/root", isDirectory: true)
    let nested = root.appendingPathComponent("a/b", isDirectory: true)
    var aggregator = DirectoryAggregator(root: root, maxChildrenPerDirectory: 2)
    aggregator.registerDirectory(FileSystemItem(url: nested, logicalSize: 0, allocatedSize: 0, isDirectory: true))
    aggregator.addFile(FileSystemItem(url: nested.appendingPathComponent("sparse.bin"), logicalSize: 10_000, allocatedSize: 2_000, isDirectory: false))
    aggregator.addFile(FileSystemItem(url: nested.appendingPathComponent("small.bin"), logicalSize: 500, allocatedSize: 500, isDirectory: false))
    aggregator.addFile(FileSystemItem(url: nested.appendingPathComponent("tiny.bin"), logicalSize: 100, allocatedSize: 100, isDirectory: false))
    let directories = aggregator.directoryItems()
    let byPath = Dictionary(uniqueKeysWithValues: directories.map { ($0.url.path, $0) })
    try expect(byPath[root.path]?.allocatedSize == 2_600, "Le parent racine doit agréger l’espace alloué")
    try expect(byPath[nested.path]?.logicalSize == 10_600, "Le dossier imbriqué doit agréger la taille logique")
    try expect(aggregator.contents(with: directories)[nested.path]?.map(\.allocatedSize) == [2_000, 500], "Les enfants doivent être bornés et triés")
}

func testConsumingAggregationMatchesSnapshot() throws {
    let root = URL(fileURLWithPath: "/tmp/StorageScopeTests/consuming-root", isDirectory: true)
    let nested = root.appendingPathComponent("missing-parent/deep", isDirectory: true)
    var aggregator = DirectoryAggregator(root: root, maxChildrenPerDirectory: 4)
    aggregator.registerDirectory(FileSystemItem(
        url: nested, logicalSize: 0, allocatedSize: 0, isDirectory: true,
        modificationDate: Date(timeIntervalSince1970: 123)
    ))
    aggregator.addFile(FileSystemItem(
        url: nested.appendingPathComponent("payload.bin"),
        logicalSize: 9_000, allocatedSize: 4_096, isDirectory: false
    ))
    aggregator.addFile(FileSystemItem(
        url: root.appendingPathComponent("direct.bin"),
        logicalSize: 300, allocatedSize: 512, isDirectory: false
    ))

    let snapshot = Dictionary(uniqueKeysWithValues: aggregator.directoryItems().map { ($0.url.path, $0) })
    let consumed = Dictionary(uniqueKeysWithValues: aggregator.takeDirectoryItems().map { ($0.url.path, $0) })
    try expect(consumed == snapshot, "La finalisation consommatrice doit produire exactement les mêmes totaux")

    var totalsOnly = DirectoryAggregator(root: root, maxRetainedFileChildren: 0)
    totalsOnly.addFile(FileSystemItem(
        url: root.appendingPathComponent("not-retained.bin"),
        logicalSize: 1, allocatedSize: 1, isDirectory: false
    ))
    try expect(totalsOnly.contents(with: []).isEmpty,
        "Le scanner doit pouvoir agréger les octets sans retenir d’enfants fichiers")
}

func testClassificationAndSafety() throws {
    try expect(FileTypeClassifier.category(for: URL(fileURLWithPath: "/tmp/movie.mov"), isDirectory: false, isPackage: false) == .video, "Classification vidéo")
    try expect(FileTypeClassifier.category(for: URL(fileURLWithPath: "/Users/me/project/node_modules"), isDirectory: true, isPackage: false) == .development, "Classification développement")
    try expect(FileTypeClassifier.category(for: URL(fileURLWithPath: "/Applications/Test.app"), isDirectory: true, isPackage: true) == .application, "Classification application")
    try expect(FileTypeClassifier.safety(for: URL(fileURLWithPath: "/System/Library/Test"), isDirectory: true) == .system, "Protection système")
    try expect(FileTypeClassifier.safety(for: URL(fileURLWithPath: "/Users/me/Downloads/image.dmg"), isDirectory: false) == .safeToReview, "Téléchargement examinable")
}

func testAccessIssueClassification() throws {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let privateIssue = ScanIssue(path: "/Users/test/Library/Mail", message: "Permission denied", isPermissionError: true)
    let systemIssue = ScanIssue(path: "/private/var/db/somewhere", message: "Operation not permitted", isPermissionError: true)
    let vanished = ScanIssue(path: "/tmp/vanished", message: "No such file", isPermissionError: false)
    try expect(AccessIssueClassifier.category(for: privateIssue, homeURL: home) == .privacy, "Les données privées du compte doivent être distinguées")
    try expect(AccessIssueClassifier.category(for: systemIssue, homeURL: home) == .system, "Les zones root doivent être classées système")
    try expect(AccessIssueClassifier.category(for: vanished, homeURL: home) == .transient, "Les fichiers disparus doivent être classés transitoires")
}

func testScanner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8_192).write(to: nested.appendingPathComponent("large.bin"))
    try Data(repeating: 2, count: 128).write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
    defer { try? FileManager.default.removeItem(at: root) }

    var final: ScanSnapshot?
    var sawProgress = false
    var sawFinalizing = false
    for await event in StorageScanner(topFileLimit: 20, topDirectoryLimit: 20, updateInterval: .milliseconds(1)).scan(root: root) {
        if case .progress = event { sawProgress = true }
        if case .finalizing = event { sawFinalizing = true }
        if case .completed(let snapshot) = event { final = snapshot }
    }
    try expect(final?.progress.filesScanned == 2, "Le scanner doit trouver les deux fichiers")
    try expect((final?.progress.skippedItems ?? 0) >= 1, "Le lien symbolique doit être ignoré")
    try expect(final?.topFiles.contains(where: { $0.name == ".hidden" }) == true, "Le fichier caché doit être indexé")
    try expect(sawProgress && sawFinalizing, "Le scanner doit publier progression légère et finalisation")
    try expect((final?.topDirectories.first(where: { $0.url.path == final?.root.path })?.allocatedSize ?? 0) > 0, "La racine doit être agrégée")
}

func testCache() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let cache = ScanCache(fileURL: file)
    let snapshot = ScanSnapshot(root: URL(fileURLWithPath: "/tmp"), progress: ScanProgress(), topFiles: [], topDirectories: [], directoryContents: [:], issues: [], completedAt: Date())
    try await cache.save(snapshot)
    let loaded = try await cache.load()
    try expect(loaded?.root.path == "/tmp", "Le cache doit survivre à un aller-retour JSON")
}

func testVolumeCacheIsolation() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StorageScopeCacheIsolation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ScanCache(baseURL: directory)
    let first = ScanSnapshot(
        root: URL(fileURLWithPath: "/Volumes/First", isDirectory: true),
        progress: ScanProgress(filesScanned: 11), topFiles: [], topDirectories: [],
        directoryContents: [:], issues: [], completedAt: Date(), volumeID: "volume-first"
    )
    let second = ScanSnapshot(
        root: URL(fileURLWithPath: "/Volumes/Second", isDirectory: true),
        progress: ScanProgress(filesScanned: 22), topFiles: [], topDirectories: [],
        directoryContents: [:], issues: [], completedAt: Date(), volumeID: "volume-second"
    )
    try await cache.save(first)
    try await cache.save(second)
    let restoredFirst = try await cache.load(volumeID: "volume-first")
    let restoredSecond = try await cache.load(volumeID: "volume-second")
    try expect(restoredFirst?.volumeID == "volume-first" && restoredFirst?.progress.filesScanned == 11,
        "Le cache du premier volume ne doit pas être remplacé par le second")
    try expect(restoredSecond?.volumeID == "volume-second" && restoredSecond?.progress.filesScanned == 22,
        "Chaque volume doit relire exclusivement son propre cache")
    let cacheFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    try expect(cacheFiles.count == 2,
        "Deux volumes doivent produire deux fichiers de cache distincts")
}

func testSelectionNormalization() throws {
    let parent = FileSystemItem(url: URL(fileURLWithPath: "/tmp/project", isDirectory: true), logicalSize: 1_000, allocatedSize: 800, isDirectory: true)
    let child = FileSystemItem(url: URL(fileURLWithPath: "/tmp/project/file.bin"), logicalSize: 500, allocatedSize: 400, isDirectory: false)
    let normalized = SelectionNormalizer.normalize([child, parent, child])
    try expect(normalized.count == 1 && normalized.first?.id == parent.id, "Un parent sélectionné doit absorber ses doublons et descendants")
}

func testCleanupSuggestions() throws {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let old = now.addingTimeInterval(-45 * 86_400)
    var analyzer = CleanupAnalyzer(homeURL: home, now: now)
    analyzer.observeFile(FileSystemItem(url: home.appendingPathComponent("Downloads/old.dmg"), logicalSize: 100 * 1_048_576, allocatedSize: 100 * 1_048_576, isDirectory: false, modificationDate: old))
    analyzer.observeFile(FileSystemItem(url: home.appendingPathComponent("Documents/never.dmg"), logicalSize: 200 * 1_048_576, allocatedSize: 200 * 1_048_576, isDirectory: false, modificationDate: old))
    let derived = FileSystemItem(url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-old", isDirectory: true), logicalSize: 500 * 1_048_576, allocatedSize: 500 * 1_048_576, isDirectory: true, modificationDate: old)
    let report = analyzer.makeReport(directories: [derived], permissionErrors: 0, isComplete: true)
    try expect(report.suggestions.contains(where: { $0.id == .oldInstallers && $0.itemCount == 1 }), "Seul l’ancien installateur de Downloads doit être suggéré")
    try expect(report.suggestions.contains(where: { $0.id == .xcodeDerivedData }), "DerivedData ancien doit être suggéré")
    try expect(report.uniquePotentialBytes == 600 * 1_048_576, "Le total des suggestions doit rester disjoint")
}

func testExactCategoryReport() async throws {
    // Avoid macOS' /var/folders cache zone: this test targets extension and package
    // precedence, not the higher-priority known-path classification.
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("StorageScopeCategories-\(UUID().uuidString)", isDirectory: true)
    let appResources = root.appendingPathComponent("Demo.app/Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1_111).write(to: root.appendingPathComponent("movie.mov"))
    try Data(repeating: 2, count: 2_222).write(to: root.appendingPathComponent("photo.jpg"))
    try Data(repeating: 3, count: 3_333).write(to: root.appendingPathComponent("unknown.blob"))
    try Data(repeating: 4, count: 4_444).write(to: appResources.appendingPathComponent("icon.png"))
    defer { try? FileManager.default.removeItem(at: root) }

    var final: ScanSnapshot?
    for await event in StorageScanner(topFileLimit: 1, topDirectoryLimit: 20).scan(root: root) {
        if case .completed(let snapshot) = event { final = snapshot }
    }
    guard let final else { throw ValidationError.failed("Le scanner doit produire un rapport final") }
    let report = final.categoryReport
    let categoryBytes = report.summaries.reduce(Int64(0)) { $0 + $1.allocatedBytes }
    let categoryFiles = report.summaries.reduce(0) { $0 + $1.fileCount }
    try expect(report.isComplete, "Le rapport final doit être marqué complet")
    try expect(report.identifiedAllocatedBytes == final.progress.allocatedBytesDiscovered, "Les catégories doivent couvrir exactement tous les octets identifiés")
    try expect(categoryBytes == report.identifiedAllocatedBytes, "La somme des catégories doit respecter l’invariant d’octets")
    try expect(categoryFiles == 4, "Chaque fichier accessible doit être compté, indépendamment de la limite Top N")
    try expect(report.summary(for: .application).fileCount == 1, "Le contenu d’un paquet .app doit hériter de la catégorie Applications")
    try expect(report.summary(for: .video).fileCount == 1 && report.summary(for: .image).fileCount == 1, "Les types médias doivent rester distincts")
    try expect(report.summary(for: .other).fileCount == 1, "Les fichiers réellement non classés doivent rester dans Autres")
}

func testExtendedCategoryPrecedence() throws {
    try expect(FileTypeClassifier.category(for: URL(fileURLWithPath: "/Applications/Demo.app/Contents/Resources/icon.png"), isDirectory: false, isPackage: false) == .application, "Un conteneur doit primer sur l’extension")
    try expect(FileTypeClassifier.category(for: URL(fileURLWithPath: "/Users/me/Library/Caches/com.demo/image.jpg"), isDirectory: false, isPackage: false) == .cacheAndLogs, "Une zone connue doit primer sur l’extension")
    try expect(FileTypeClassifier.category(for: URL(fileURLWithPath: "/Users/me/Library/Application Support/Demo/data.bin"), isDirectory: false, isPackage: false) == .applicationData, "Les données d’application doivent être distinguées")
    try expect(FileTypeClassifier.category(for: URL(fileURLWithPath: "/Users/me/Library/Messages/Attachments/photo.heic"), isDirectory: false, isPackage: false) == .mailAndMessages, "Mail et Messages doivent être distingués")
}

func testScannerThroughput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeBenchmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let payload = Data(repeating: 7, count: 64)
    let fileCount = 5_000
    for directoryIndex in 0..<20 {
        let directory = root.appendingPathComponent("d\(directoryIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fileIndex in 0..<(fileCount / 20) {
            FileManager.default.createFile(atPath: directory.appendingPathComponent("f\(fileIndex)").path, contents: payload)
        }
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = ContinuousClock()
    let start = clock.now
    var scanned = 0
    for await event in StorageScanner(topFileLimit: 100, topDirectoryLimit: 100).scan(root: root) {
        if case .completed(let snapshot) = event { scanned = snapshot.progress.filesScanned }
    }
    let elapsed = start.duration(to: clock.now)
    let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    let rate = Double(scanned) / seconds
    print("  Débit synthétique : \(Int(rate).formatted()) fichiers/s (\(scanned) fichiers)")
    try expect(scanned == fileCount, "Le benchmark doit analyser tous les fichiers")
    try expect(rate > 300, "Le scanner optimisé doit dépasser 300 fichiers/s sur le corpus synthétique")
}

func testExhaustiveDirectoryBrowser() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeBrowser-\(UUID().uuidString)", isDirectory: true)
    let indexedFolder = root.appendingPathComponent("indexed", isDirectory: true)
    let database = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeIndex-\(UUID().uuidString).sqlite")
    try FileManager.default.createDirectory(at: indexedFolder, withIntermediateDirectories: true)
    for index in 0..<301 {
        FileManager.default.createFile(atPath: root.appendingPathComponent("file-\(index).bin").path, contents: Data([UInt8(index % 255)]))
    }
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: database)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
    }

    let volumeID = "browser-test"
    let store = try DirectoryIndexStore(volumeID: volumeID, root: root, databaseURL: database)
    try await store.replaceAll([
        DirectorySummary(volumeID: volumeID, url: root, logicalSize: 9_999, allocatedSize: 9_999),
        DirectorySummary(volumeID: volumeID, url: indexedFolder, logicalSize: 4_242, allocatedSize: 4_242)
    ], scanID: UUID(), indexVersion: 1)
    let browser = DirectoryBrowserService(volumeID: volumeID, root: root, indexStore: store)
    var items: [FileSystemItem] = []
    for await event in browser.browse(directory: root, options: DirectoryBrowseOptions(batchSize: 17)) {
        if case .batch(_, let batch) = event { items.append(contentsOf: batch) }
    }
    try expect(items.count == 302, "Le navigateur doit restituer tous les enfants au-delà de l’ancienne limite de 250")
    try expect(items.first(where: { $0.url.path == indexedFolder.path })?.allocatedSize == 4_242, "La taille SQLite du sous-dossier doit enrichir la navigation à la demande")
}

func testSafeTrashPreflight() async throws {
    let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".StorageScopeTrash-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let item = FileSystemItem(url: file, logicalSize: 3, allocatedSize: 3, isDirectory: false)
    let preflight = await TrashService().preflight([item])
    try expect(preflight.count == 1 && preflight[0].isReady, "Le préflight doit capturer une identité inode/volume avant mutation : \(preflight.first?.errorDescription ?? "résultat absent")")
    let protected = FileSystemItem(url: URL(fileURLWithPath: "/System"), logicalSize: 0, allocatedSize: 0, isDirectory: true, safety: .system)
    let protectedResult = await TrashService().preflight([protected])
    try expect(protectedResult.first?.isReady == false, "Un chemin système doit être refusé avant toute suppression")
}

func testSignedDeviceIdentifierBitPattern() throws {
    try expect(
        FileIdentity.deviceID(fromRawValue: -1) == UInt64(UInt32.max),
        "Un dev_t avec bit haut posé doit conserver son motif binaire sans trap"
    )
    try expect(
        FileIdentity.deviceID(fromRawValue: Int32.min) == UInt64(UInt32(bitPattern: Int32.min)),
        "Le scanner doit accepter les identifiants de volume représentés par un Int32 négatif"
    )
}

func testSaturatingScannerArithmetic() throws {
    let saturatedBytes: Int64 = SaturatingArithmetic.addNonnegative(Int64.max, 1)
    let saturatedCount: Int = SaturatingArithmetic.addNonnegative(Int.max, 1)
    try expect(saturatedBytes == Int64.max, "La somme d’octets max + 1 doit saturer sans trap")
    try expect(saturatedCount == Int.max, "Le compteur max + 1 doit saturer sans trap")

    let root = URL(fileURLWithPath: "/tmp/StorageScopeOverflow/root", isDirectory: true)
    var aggregator = DirectoryAggregator(root: root, maxRetainedFileChildren: 0)
    aggregator.addFile(FileSystemItem(
        url: root.appendingPathComponent("huge-sparse-a"),
        logicalSize: Int64.max,
        allocatedSize: Int64.max,
        isDirectory: false
    ))
    aggregator.addFile(FileSystemItem(
        url: root.appendingPathComponent("huge-sparse-b"),
        logicalSize: 1,
        allocatedSize: 1,
        isDirectory: false
    ))
    let aggregate = aggregator.directoryItems().first { $0.url.path == root.path }
    try expect(
        aggregate?.logicalSize == Int64.max && aggregate?.allocatedSize == Int64.max,
        "Le fold des dossiers doit saturer sur Int64.max + 1"
    )

    let home = URL(fileURLWithPath: "/Users/overflow-test", isDirectory: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let old = now.addingTimeInterval(-45 * 86_400)
    var analyzer = CleanupAnalyzer(homeURL: home, now: now)
    for (name, size) in [("huge-a.dmg", Int64.max), ("huge-b.dmg", Int64(50 * 1_048_576))] {
        analyzer.observeFile(FileSystemItem(
            url: home.appendingPathComponent("Downloads/\(name)"),
            logicalSize: size,
            allocatedSize: size,
            isDirectory: false,
            modificationDate: old
        ))
    }
    let report = analyzer.makeReport(directories: [], permissionErrors: 0, isComplete: true)
    try expect(
        report.suggestions.first(where: { $0.id == .oldInstallers })?.potentialBytes == Int64.max,
        "Le calcul du nettoyage doit saturer sur Int64.max + 1"
    )
}

func testNegativeTopItemLimits() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StorageScopeNegativeLimit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1]).write(to: root.appendingPathComponent("file.bin"))
    defer { try? FileManager.default.removeItem(at: root) }

    var completed: ScanSnapshot?
    for await event in StorageScanner(topFileLimit: Int.min, topDirectoryLimit: -1).scan(
        root: root,
        volumeID: "negative-heap-limit-regression"
    ) {
        if case .completed(let snapshot) = event { completed = snapshot }
    }
    try expect(completed?.progress.filesScanned == 1, "Une limite négative doit être normalisée sans trap")
    try expect(completed?.topFiles.count == 1, "Le tas doit conserver une capacité minimale de un")
}

func testScannerOnDeviceFilesystem() async throws {
    let deviceRoot = URL(fileURLWithPath: "/dev", isDirectory: true)
    guard FileManager.default.fileExists(atPath: deviceRoot.path) else { return }
    var completed = false
    for await event in StorageScanner(topFileLimit: 10, topDirectoryLimit: 10).scan(
        root: deviceRoot, volumeID: "device-filesystem-regression"
    ) {
        if case .completed = event { completed = true }
    }
    try expect(completed, "Le scanner doit traverser /dev sans trap sur un dev_t à bit haut")
}

func testDuplicateAnalysis() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeDuplicates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repeated = Data(repeating: 9, count: 32_768)
    try repeated.write(to: root.appendingPathComponent("copy-a.bin"))
    try repeated.write(to: root.appendingPathComponent("copy-b.bin"))
    try Data(repeating: 4, count: 32_768).write(to: root.appendingPathComponent("different.bin"))
    defer { try? FileManager.default.removeItem(at: root) }

    let report = await DuplicateAnalysisService().analyze(root: root, minimumSize: 1_024)
    try expect(report.isComplete, "L’analyse de doublons doit se terminer")
    try expect(report.groups.count == 1 && report.groups[0].files.count == 2, "Seuls les deux contenus strictement identiques doivent être groupés")
}

func testTreemapLayout() throws {
    let values = [
        TreemapValue(id: "documents", weight: 60),
        TreemapValue(id: "video", weight: 25),
        TreemapValue(id: "apps", weight: 10),
        TreemapValue(id: "other", weight: 5)
    ]
    let bounds = TreemapRect(x: 11, y: 17, width: 1_000, height: 600)
    let first = TreemapLayoutEngine.layout(values, in: bounds)
    let second = TreemapLayoutEngine.layout(values.reversed(), in: bounds)

    try expect(first == second, "Le treemap doit être déterministe, indépendamment de l’ordre d’entrée")
    try expect(first.count == values.count, "Chaque valeur positive doit produire une tuile")

    let epsilon = 0.000_001
    for tile in first {
        try expect(tile.rect.x >= bounds.x - epsilon && tile.rect.y >= bounds.y - epsilon, "Une tuile ne doit pas dépasser l’origine du cadre")
        try expect(tile.rect.maxX <= bounds.maxX + epsilon && tile.rect.maxY <= bounds.maxY + epsilon, "Une tuile doit rester contenue dans le cadre")
        let expectedFraction = Double(tile.weight) / 100
        try expect(abs(tile.rect.area / bounds.area - expectedFraction) < epsilon, "L’aire de chaque tuile doit être proportionnelle à ses octets")
    }

    for leftIndex in first.indices {
        for rightIndex in first.indices where rightIndex > leftIndex {
            let left = first[leftIndex].rect
            let right = first[rightIndex].rect
            let overlapWidth = min(left.maxX, right.maxX) - max(left.x, right.x)
            let overlapHeight = min(left.maxY, right.maxY) - max(left.y, right.y)
            try expect(overlapWidth <= epsilon || overlapHeight <= epsilon, "Les tuiles du treemap ne doivent jamais se chevaucher")
        }
    }
    try expect(abs(first.reduce(0) { $0 + $1.rect.area } - bounds.area) < epsilon, "Le treemap doit couvrir toute la surface disponible")

    let stressValues = (0..<240).map { TreemapValue(id: "item-\(String(format: "%03d", $0))", weight: Int64(($0 % 19) + 1)) }
    let stress = TreemapLayoutEngine.layout(stressValues, in: TreemapRect(x: 0, y: 0, width: 1_440, height: 900))
    for leftIndex in stress.indices {
        for rightIndex in stress.indices where rightIndex > leftIndex {
            let left = stress[leftIndex].rect
            let right = stress[rightIndex].rect
            let overlapWidth = min(left.maxX, right.maxX) - max(left.x, right.x)
            let overlapHeight = min(left.maxY, right.maxY) - max(left.y, right.y)
            try expect(overlapWidth <= epsilon || overlapHeight <= epsilon, "Le treemap dense ne doit pas se chevaucher")
        }
    }
}

func testTreemapZeroAndGrouping() throws {
    let mixed = TreemapLayoutEngine.layout([
        TreemapValue(id: "known", weight: 10),
        TreemapValue(id: "pending", weight: 0)
    ])
    try expect(mixed.first(where: { $0.id == "known" })?.rect.area == 1, "Une taille connue doit conserver toute l’aire face à une taille nulle")
    try expect(mixed.first(where: { $0.id == "pending" })?.rect.area == 0, "Une taille nulle mixte doit rester mathématiquement nulle")
    try expect(mixed.allSatisfy { $0.rect.x.isFinite && $0.rect.y.isFinite && $0.rect.width.isFinite && $0.rect.height.isFinite }, "Les tailles nulles ne doivent jamais produire NaN ou infini")

    let allZero = TreemapLayoutEngine.layout((0..<4).map { TreemapValue(id: "pending-\($0)", weight: 0) })
    try expect(allZero.count == 4, "Les éléments encore sans taille doivent rester visibles")
    try expect(allZero.allSatisfy { abs($0.rect.area - 0.25) < 0.000_001 }, "Un dossier entièrement non mesuré doit répartir la surface équitablement")

    let partition = TreemapLayoutEngine.partition(
        [TreemapValue(id: "large", weight: 990)] + (0..<25).map { TreemapValue(id: "tiny-\($0)", weight: 1) },
        maximumVisibleItems: 12,
        minimumVisibleFraction: 0.003
    )
    try expect(partition.visible.map(\.id) == ["large"], "Les surfaces minuscules doivent être sorties de la carte principale")
    try expect(partition.grouped.count == 25, "Tous les petits éléments doivent rester disponibles dans le groupe ouvrable")
}

func testCriticalDeletionBoundaries() async throws {
    let home = URL(fileURLWithPath: "/Users/security-test", isDirectory: true)
    let protectedPaths = [
        home,
        home.appendingPathComponent("Library", isDirectory: true),
        home.appendingPathComponent("Library/Keychains", isDirectory: true),
        home.appendingPathComponent("Library/Mail/V10", isDirectory: true),
        home.appendingPathComponent("Library/Messages", isDirectory: true),
        home.appendingPathComponent("Library/Safari", isDirectory: true),
        home.appendingPathComponent("Library/Containers/com.example.app", isDirectory: true),
        home.appendingPathComponent("Library/Group Containers/group.com.example", isDirectory: true),
        home.appendingPathComponent("Library/Mobile Documents", isDirectory: true),
        home.appendingPathComponent("Library/CloudStorage", isDirectory: true),
        home.appendingPathComponent("Pictures/Photos Library.photoslibrary", isDirectory: true)
    ]
    for url in protectedPaths {
        try expect(
            FileTypeClassifier.safety(for: url, isDirectory: true) == .system,
            "La zone critique doit être classée système : \(url.path)"
        )
        let item = FileSystemItem(
            url: url, logicalSize: 0, allocatedSize: 0, isDirectory: true, safety: .review
        )
        try expect(!item.isTrashable, "Une safety injectée ne doit pas contourner la politique : \(url.path)")
    }

    let thirdPartyCache = home.appendingPathComponent("Library/Caches/com.example.RenderCache", isDirectory: true)
    try expect(
        FileTypeClassifier.safety(for: thirdPartyCache, isDirectory: true) == .safeToReview,
        "Un cache tiers précis doit rester examinable"
    )
    let downloadedFile = home.appendingPathComponent("Downloads/old-installer.dmg")
    try expect(
        FileTypeClassifier.safety(for: downloadedFile, isDirectory: false) == .safeToReview,
        "Un fichier précis dans Téléchargements doit rester examinable"
    )

    let liveHome = FileManager.default.homeDirectoryForCurrentUser
    let liveCriticalItems = [
        FileSystemItem(url: liveHome, logicalSize: 0, allocatedSize: 0, isDirectory: true, safety: .review),
        FileSystemItem(url: liveHome.appendingPathComponent("Library", isDirectory: true),
            logicalSize: 0, allocatedSize: 0, isDirectory: true, safety: .review),
        FileSystemItem(url: liveHome.appendingPathComponent("Library/Keychains", isDirectory: true),
            logicalSize: 0, allocatedSize: 0, isDirectory: true, safety: .review)
    ]
    let serviceResults = await TrashService().preflight(liveCriticalItems)
    try expect(serviceResults.allSatisfy { !$0.isReady }, "TrashService doit refuser directement les zones utilisateur critiques")
}

func testPreparedTrashRejectsSubstitution() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let identifier = UUID().uuidString
    let target = root.appendingPathComponent(".StorageScopePrepared-\(identifier)")
    let original = root.appendingPathComponent(".StorageScopePreparedOriginal-\(identifier)")
    try Data("original".utf8).write(to: target)
    defer {
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: original)
    }

    let item = FileSystemItem(url: target, logicalSize: 8, allocatedSize: 8, isDirectory: false)
    let service = TrashService()
    let prepared = await service.preflight([item])
    try expect(prepared.first?.isReady == true, "Le fichier initial doit être préparé")
    try FileManager.default.moveItem(at: target, to: original)
    try Data("replacement".utf8).write(to: target)

    let results = await service.trashWithResults(prepared)
    try expect(results.first?.status == .failed, "La substitution inode doit être refusée après confirmation")
    try expect(FileManager.default.fileExists(atPath: target.path), "Le fichier substitué ne doit pas être déplacé")
}

func testBundleIdentifierAndExplorerApplicationIdentity() async throws {
    try expect(BundleIdentifierValidator.isValid("com.example.Safe-App"), "Un bundle ID reverse-DNS valide doit être accepté")
    for invalid in ["", "example", "../escape", "com..escape", "com.example/escape", "com.example\\escape", "com.example. white"] {
        try expect(!BundleIdentifierValidator.isValid(invalid), "Bundle ID dangereux accepté : \(invalid)")
    }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let app = root.appendingPathComponent(".StorageScopeExplorerFixture-\(UUID().uuidString).app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app) }
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.StorageFixture",
        "CFBundleName": "StorageFixture",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1"
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))

    let discovered = await ApplicationDiscoveryService().application(at: app)
    try expect(discovered?.bundleIdentifier == "com.example.StorageFixture", "L’app Explorer doit lire son vrai bundle ID")
    try expect(discovered?.bundleIdentity != nil, "L’app Explorer doit capturer dev/inode/type avant le plan")
    if let discovered {
        let plan = await UninstallService().makePlan(for: discovered)
        try expect(plan.candidates.first(where: { $0.group == .applicationBundle })?.expectedIdentity == discovered.bundleIdentity,
            "Le plan doit conserver l’identité capturée du bundle")

        let fakeHome = root.appendingPathComponent(".StorageScopeAssociationHome-\(UUID().uuidString)", isDirectory: true)
        let preferences = fakeHome.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let exactPreference = preferences.appendingPathComponent("com.example.StorageFixture.plist")
        let neighboringPreference = preferences.appendingPathComponent("com.example.StorageFixture2.plist")
        try Data().write(to: exactPreference)
        try Data().write(to: neighboringPreference)
        let associations = await AppAssociationFinder(homeURL: fakeHome).candidates(for: discovered)
        try expect(associations.contains { $0.url.standardizedFileURL.path == exactPreference.path },
            "La préférence portant l’identifiant exact doit être associée")
        try expect(!associations.contains { $0.url.standardizedFileURL.path == neighboringPreference.path },
            "Un identifiant voisin ne doit jamais être capturé")

        let malicious = InstalledApplication(
            bundleURL: app, bundleIdentifier: "../Library/Keychains", displayName: "Malicious",
            version: nil, allocatedBytesUpperBound: 0, bundleIdentity: discovered.bundleIdentity
        )
        let maliciousPlan = await UninstallService().makePlan(for: malicious)
        try expect(!maliciousPlan.canProceed && maliciousPlan.candidates.isEmpty,
            "Un bundle ID contenant un path escape ne doit produire aucun candidat")
    }
}

@main
struct StorageCoreTests {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("Agrégation", { try testAggregation() }),
            ("Agrégation consommatrice", { try testConsumingAggregationMatchesSnapshot() }),
            ("Classification et sécurité", { try testClassificationAndSafety() }),
            ("Classification des refus d’accès", { try testAccessIssueClassification() }),
            ("Scanner, fichiers cachés et symlinks", { try await testScanner() }),
            ("Cache local", { try await testCache() }),
            ("Caches isolés par volume", { try await testVolumeCacheIsolation() }),
            ("Normalisation de sélection", { try testSelectionNormalization() }),
            ("Suggestions conservatrices", { try testCleanupSuggestions() }),
            ("Catégories exactes", { try await testExactCategoryReport() }),
            ("Priorité des catégories", { try testExtendedCategoryPrecedence() }),
            ("Navigation exhaustive SQLite", { try await testExhaustiveDirectoryBrowser() }),
            ("Préflight Corbeille", { try await testSafeTrashPreflight() }),
            ("Identifiants de volume signés", { try testSignedDeviceIdentifierBitPattern() }),
            ("Arithmétique saturante du scanner", { try testSaturatingScannerArithmetic() }),
            ("Limites négatives du tas", { try await testNegativeTopItemLimits() }),
            ("Scan système de fichiers /dev", { try await testScannerOnDeviceFilesystem() }),
            ("Doublons SHA-256", { try await testDuplicateAnalysis() }),
            ("Treemap proportionnel", { try testTreemapLayout() }),
            ("Treemap tailles nulles et regroupement", { try testTreemapZeroAndGrouping() }),
            ("Frontières suppression critiques", { try await testCriticalDeletionBoundaries() }),
            ("Identité avant confirmation", { try await testPreparedTrashRejectsSubstitution() }),
            ("Bundle ID et app Explorer", { try await testBundleIdentifierAndExplorerApplicationIdentity() }),
            ("Débit du scanner", { try await testScannerThroughput() })
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("✓ \(name)") }
            catch { failures += 1; print("✗ \(name): \(error)") }
        }
        if failures > 0 { exit(EXIT_FAILURE) }
        print("\n\(tests.count) tests réussis")
    }
}
