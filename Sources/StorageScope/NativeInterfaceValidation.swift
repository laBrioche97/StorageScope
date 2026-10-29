import AppKit
import StorageCore
import SwiftUI
import Sparkle

/// Offscreen native rendering, invoked only by the explicit CI validation command.
@MainActor
enum NativeInterfaceValidation {
    static func run() async throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments.last ?? "/tmp/storagescope-ui")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let model = AppModel()
        let sizeFixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".StorageScopeUninstallSize-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: sizeFixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sizeFixtureRoot) }
        try Data(repeating: 97, count: 131_072).write(to: sizeFixtureRoot.appendingPathComponent("payload"))
        let fixtureApp = InstalledApplication(bundleURL: sizeFixtureRoot, bundleIdentifier: "com.labrioche.size-fixture", displayName: "Size fixture", version: "1", allocatedBytesUpperBound: 0)
        let fixtureCandidate = UninstallCandidate(url: sizeFixtureRoot, group: .applicationBundle, reason: "Disposable size validation", allocatedBytesUpperBound: 0, isDirectory: true, isPackage: true, expectedIdentity: nil, isRemovable: true, isSelectedByDefault: true)
        let sizeModel = AppModel()
        let sizePlan = UninstallPlan(application: fixtureApp, candidates: [fixtureCandidate], isRunning: false)
        sizeModel.uninstallPlan = sizePlan
        sizeModel.isScanning = true
        sizeModel.performUninstall(allowFinderAuthorization: true)
        precondition(!sizeModel.uninstallActionMessage.isEmpty && !sizeModel.uninstallIsWorking,
            "A busy continuation must explain its block instead of silently doing nothing")
        sizeModel.isScanning = false
        precondition(sizeModel.uninstallSelectionSummary(sizePlan).contains("indisponible"))
        await sizeModel.measureUninstallPlan()
        precondition(sizeModel.uninstallSizes[sizeFixtureRoot.path]?.state == .measured && (sizeModel.uninstallSizes[sizeFixtureRoot.path]?.bytes ?? 0) > 0, "Confirmation must measure the bundle, not its directory metadata")
        precondition(sizeModel.uninstallSelectionSummary(sizePlan).contains("Taille mesurée"))
        let updates = SoftwareUpdates()
        let probe = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updates, delegate: updates)
        updates.updater(probe, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        precondition(updates.status == "Aucune mise à jour compatible disponible.")
        updates.updater(probe, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: 1002, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)]))
        precondition(updates.status.contains("Connexion indisponible"))
        updates.updater(probe, didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
        precondition(updates.status.contains("Vérification impossible") && updates.symbol != "checkmark.circle")
        precondition(model.sidebar == .applications && SidebarSection.allCases.first == .applications)
        for asset in ["classic-library", "classic-menu", "new-library", "new-game"] {
            precondition(EpicGuideResources.bundle.url(forResource: asset, withExtension: "png", subdirectory: "EpicGuide") != nil, "Offline Epic guide asset missing")
        }
        let storageModel = AppModel()
        let fixture = StorageVolume(id: "fixture", url: URL(fileURLWithPath: "/Volumes/Fixture"), name: "Disque de démonstration", capacity: 0, available: 0, isLocal: true, isInternal: false, statisticsAvailable: false)
        storageModel.volumes = [fixture]; storageModel.selectedVolumeID = fixture.id; storageModel.sidebar = .explorer
        storageModel.explorerDisplayMode = .bubbles; storageModel.searchText = "masqué"
        storageModel.openExplorerStorage(id: fixture.id)
        precondition(storageModel.currentDirectory == fixture.url && storageModel.searchText.isEmpty && storageModel.explorerDisplayMode == .bubbles)
        storageModel.showExplorerStorages(); precondition(storageModel.choosingExplorerStorage)
        let source = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let first = model.iconCache.image(for: source)
        precondition(first === model.iconCache.image(for: source), "Session logo cache must reuse decoded images")
        model.searchText = "Applications"; model.sidebar = .explorer
        precondition(model.searchText.isEmpty)
        model.searchText = "Dossiers"; model.sidebar = .applications
        precondition(model.searchText == "Applications")
        model.sidebar = .explorer; precondition(model.searchText == "Dossiers"); model.resetSectionFilters()
        model.showDirectFiles()
        precondition(model.explorerDisplayMode == .bubbles && !model.explorerShowsGraph)
        model.loadExplorerDirectory(URL(fileURLWithPath: "/Volumes/Test/Child"))
        precondition(model.explorerShowsGraph && model.kindFilter == .all)
        model.explorerDisplayMode = .list
        model.loadExplorerDirectory(URL(fileURLWithPath: "/Volumes/Test/Child"))
        precondition(!model.explorerShowsGraph && model.explorerDisplayMode == .list)
        model.explorerDisplayMode = .bubbles
        let weights: [Int64] = [40, 25, 15, 10, 5]
        model.explorerItems = weights.enumerated().map { index, bytes in
            FileSystemItem(url: URL(fileURLWithPath: "/Volumes/Test/Item-\(index)"), name: ["Applications", "Documents", "Jeux", "Vidéo.mp4", "Archives.zip"][index], logicalSize: bytes * 1_073_741_824, allocatedSize: bytes * 1_073_741_824, isDirectory: index < 3, category: index == 3 ? .video : index == 4 ? .archive : .other, sizeIsKnown: true)
        }
        model.bubbleFrame = try ExplorerBubbleLayout.frame(path: "/Volumes/Test", items: model.explorerItems, total: 95 * 1_073_741_824, partial: false)
        precondition(model.bubbleFrame?.folders.count == 5 && model.bubbleFrame?.folders.allSatisfy { $0.depth == 0 } == true)
        model.bubbleMessage = "Tailles mesurées · Dossiers et fichiers de ce niveau"
        model.currentDirectory = URL(fileURLWithPath: "/Volumes/Test")
        for (width, height, suffix) in [(1120.0, 800.0, "large"), (740.0, 560.0, "small")] {
        model.bubbleFrame = try ExplorerBubbleLayout.frame(path: "/Volumes/Test", items: model.explorerItems, total: 95 * 1_073_741_824, partial: false, availableDiameter: height < 600 ? 180 : 400)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for scale in [1.0, 2.0] {
                let view = ContentView().environmentObject(model).environmentObject(model.explorer).environmentObject(SoftwareUpdates())
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: width, height: height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width * scale, height: height * scale, alignment: .topLeading)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width * scale, height: height * scale), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: width * scale, height: height * scale)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: destination.appendingPathComponent("macos-bubbles-\(suffix)-\(dark ? "dark" : "light")-\(Int(scale * 100)).png"))
                window.close()
            }
        }
        }
        let demoGame = ManagedGame(id: "guide-demo", name: "Jeu de démonstration", provider: .epic, installURL: URL(fileURLWithPath: "/tmp/StorageScopeGuideDemo"), manifestURL: URL(fileURLWithPath: "/tmp/StorageScopeGuideDemo.item"), uninstallURL: nil)
        let guide = EpicGuideController(game: demoGame, model: model)
        defer { guide.close() }
        for modern in [false, true] {
            let view = EpicGuideView(guide: guide, modern: modern).environment(\.colorScheme, .dark).frame(width: 740, height: 560).background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            guide.window?.appearance = NSAppearance(named: .darkAqua)
            guide.window?.setContentSize(NSSize(width: 740, height: 560))
            guide.window?.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 740, height: 560); hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: destination.appendingPathComponent("macos-epic-guide-\(modern ? "new" : "classic").png"))
        }
        precondition(!guide.started && !guide.finished, "Rendering the guide must not launch an uninstaller")
        print("PASS native macOS bubble rendering at 100/200%, light/dark, cached icons, storage roots and both offline Epic guide presentations")
    }
}
