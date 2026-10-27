import AppKit
import Foundation
import QuickLookUI
import StorageCore
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case applications = "Applications et jeux"
    case overview = "Vue d’ensemble"
    case explorer = "Explorateur"
    case largestFiles = "Plus gros fichiers"
    case largestFolders = "Plus gros dossiers"
    case categories = "Catégories"
    case cleanup = "Nettoyage conseillé"
    case volumes = "Volumes"
    case lastScan = "Dernier scan"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .explorer: "square.grid.3x3.fill"
        case .largestFiles: "doc.fill"
        case .largestFolders: "folder.fill"
        case .categories: "square.grid.2x2.fill"
        case .cleanup: "sparkles"
        case .applications: "app.dashed"
        case .volumes: "internaldrive.fill"
        case .lastScan: "clock.arrow.circlepath"
        }
    }
}

enum SizeFilter: Int64, CaseIterable, Identifiable {
    case all = 0
    case mb100 = 104_857_600
    case mb500 = 524_288_000
    case gb1 = 1_073_741_824
    case gb5 = 5_368_709_120
    case gb10 = 10_737_418_240
    var id: Int64 { rawValue }
    var label: String {
        switch self { case .all: "Tout"; case .mb100: "100 Mo"; case .mb500: "500 Mo"; case .gb1: "1 Go"; case .gb5: "5 Go"; case .gb10: "10 Go" }
    }
}

enum ItemSort: String, CaseIterable, Identifiable {
    case allocated = "Taille décroissante"
    case smallest = "Taille croissante"
    case name = "Nom"
    case type = "Type"
    case date = "Date"
    case path = "Chemin"
    var id: String { rawValue }
}

enum FileKindFilter: String, CaseIterable, Identifiable {
    case all = "Fichiers et dossiers", files = "Fichiers seulement", folders = "Dossiers seulement"
    var id: String { rawValue }
}

enum ExplorerDisplayMode: String, CaseIterable, Identifiable {
    case bubbles = "Liste et bulles"
    case list = "Liste seule"
    var id: String { rawValue }
}

struct ExplorerCategoryContext: Equatable {
    let category: ItemCategory
    let totalLogicalBytes: Int64
    let totalAllocatedBytes: Int64
    let totalFileCount: Int
    let knownItemCount: Int
    let knownAllocatedBytes: Int64
    let reportIsComplete: Bool
    let generatedAt: Date
}

enum EmptyTrashStep { case inventory, confirmation, running, result }

@MainActor
final class ScanStatus: ObservableObject {
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var isFinalizing = false
    private(set) var expectedItemCount: Int?

    var estimatedFraction: Double? {
        guard let expectedItemCount, expectedItemCount > 0 else { return nil }
        let current = progress.filesScanned + progress.directoriesScanned
        return min(0.99, Double(current) / Double(expectedItemCount))
    }

    func begin(expectedItemCount: Int?) {
        progress = ScanProgress()
        isFinalizing = false
        self.expectedItemCount = expectedItemCount
    }

    func update(_ progress: ScanProgress, finalizing: Bool = false) {
        self.progress = progress
        isFinalizing = finalizing
    }
}

@MainActor
final class AppModel: ObservableObject {
    let isPreviewMode = CommandLine.arguments.contains("--verify-interface")
    @Published var trashIsWorking = false
    @Published var gameUninstallIsWorking = false
    @Published var updateIsWorking = false
    var operationsAreBusy: Bool { updateIsWorking || localOperationsAreBusy }
    var localOperationsAreBusy: Bool {
        isScanning || cleanupIsAnalyzing || duplicateIsAnalyzing || uninstallIsWorking || trashIsWorking || gameUninstallIsWorking || emptyTrashStep == .running
    }
    private struct SectionFilters {
        var search: String; var size: SizeFilter; var category: ItemCategory?; var order: ItemSort; var kind: FileKindFilter
    }
    private var sectionFilters: [SidebarSection: SectionFilters] = [:]
    @Published var sidebar: SidebarSection? = .applications {
        didSet {
            guard oldValue != sidebar else { return }
            if let oldValue { sectionFilters[oldValue] = SectionFilters(search: searchText, size: sizeFilter, category: categoryFilter, order: sort, kind: kindFilter) }
            let next = sidebar.flatMap { sectionFilters[$0] }
            searchText = next?.search ?? ""; sizeFilter = next?.size ?? .all; categoryFilter = next?.category
            sort = next?.order ?? .allocated; kindFilter = next?.kind ?? .all
            selectedIDs.removeAll()
        }
    }
    @Published var volumes: [StorageVolume]
    @Published var selectedVolumeID: String
    @Published var choosingExplorerStorage = false
    @Published var storageChoiceMessage = "Choisissez un stockage pour ouvrir sa racine."
    @Published var snapshot: ScanSnapshot?
    @Published var liveSummary: ScanLiveSummary?
    @Published var isScanning = false
    @Published var searchText = ""
    @Published var sizeFilter: SizeFilter = .all
    @Published var categoryFilter: ItemCategory?
    @Published var sort: ItemSort = .allocated
    @Published var kindFilter: FileKindFilter = .all
    @Published var selectedIDs: Set<String> = []
    @Published var currentDirectory: URL?
    @Published var explorerItems: [FileSystemItem] = []
    @Published var explorerIssues: [ScanIssue] = []
    @Published var explorerIsLoading = false
    @Published var explorerLoaderVisible = false
    @Published var explorerPendingDirectory: URL?
    @Published var explorerVisited = 0
    @Published var navigationRevision = UUID()
    @Published var navigationBack = false
    @Published var navigationAnchor = UnitPoint.center
    var explorerScrollPosition: Double = .nan
    private var explorerViewCache = ExplorerSessionCache()
    private var explorerSortedSnapshot: ExplorerViewSnapshot?
    private var loaderTask: Task<Void, Never>?
    private var explorerLayoutKey: String { "\(maximumBubbles):\(Int(bubbleAvailableDiameter.isFinite ? bubbleAvailableDiameter / 16 : 0)):\(NSApp.keyWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1):\(explorerDisplayMode)" }
    private func explorerCacheKey(_ directory: URL) -> String { selectedVolumeID + "|" + scanGeneration.uuidString + "|" + directory.path }
    private func saveExplorerView() {
        guard let directory = currentDirectory, explorerPendingDirectory == nil,
              var view = explorerViewCache.get(explorerCacheKey(directory)) else { return }
        view.selection = selectedIDs; view.scroll = explorerScrollPosition; view.frame = bubbleFrame; view.layout = explorerLayoutKey
        explorerViewCache.put(explorerCacheKey(directory), view)
    }
    private func publishExplorerView(_ view: ExplorerViewSnapshot, directory: URL, back: Bool, animate: Bool, recordHistory: Bool = true) {
        let previous = currentDirectory
        currentDirectory = directory; explorerItems = view.items; bubbleFrame = view.frame
        explorerSortedSnapshot = view
        selectedIDs = view.selection; explorerScrollPosition = view.scroll
        encounteredApplicationURLs.formUnion(view.items.filter { $0.isDirectory && $0.fileExtension == "app" }.map(\.url))
        if recordHistory && (explorerHistoryPosition < 0 || explorerHistory[explorerHistoryPosition] != directory) {
            explorerHistory = Array(explorerHistory.prefix(explorerHistoryPosition + 1)); explorerHistory.append(directory); explorerHistoryPosition = explorerHistory.count - 1
        }
        explorerPendingDirectory = nil; explorerLoaderVisible = false; loaderTask?.cancel()
        bubbleMessage = view.frame?.totalBytes.map { ByteCountFormatter.storage.string(fromByteCount: $0) + (view.frame?.isPartial == true ? " · analyse partielle" : " · tailles mesurées") } ?? "Tailles inconnues · analysez le disque pour compléter les bulles."
        navigationBack = back
        if animate && previous != directory { navigationRevision = UUID() }
    }

    @Published var explorerDisplayMode: ExplorerDisplayMode = .bubbles {
        didSet { resetExplorerTemporaryList() }
    }
    @Published var explorerTemporaryList = false
    var explorerShowsGraph: Bool { explorerDisplayMode == .bubbles && !explorerTemporaryList && explorerCategoryContext == nil }

    func resetExplorerTemporaryList() {
        if explorerTemporaryList { kindFilter = .all }
        explorerTemporaryList = false; bubbleRemainderPaths = nil
    }
    @Published var explorerShowsSmallItems = false
    @Published var explorerCategoryContext: ExplorerCategoryContext?
    @Published var cleanupIsAnalyzing = false
    @Published var cleanupProgress: CleanupAnalysisProgress?
    @Published var validatedCleanupReport: CleanupReport?
    @Published var duplicateIsAnalyzing = false
    @Published var duplicateProgress: DuplicateAnalysisProgress?
    @Published var duplicateReport: DuplicateAnalysisReport?
    @Published var duplicateSelectedIDs: Set<String> = []
    @Published var duplicateError: String?
    @Published var showingEmptyTrash = false
    @Published var emptyTrashStep: EmptyTrashStep = .inventory
    @Published private(set) var trashSummaryIsLoading = false
    @Published var trashSummary: TrashInventory?
    @Published var trashInventory: TrashInventory?
    @Published var emptyTrashConfirmation = ""
    @Published var emptyTrashResult: EmptyTrashResult?
    @Published var trashInventoryIsLoading = false
    @Published var applicationProtectionFilter = 0
    @Published var applications: [InstalledApplication] = []
    @Published var applicationsAreLoading = false
    @Published var showingUninstall = false
    @Published var uninstallPlan: UninstallPlan?
    @Published var uninstallSelectedIDs: Set<String> = []
    @Published var uninstallIsWorking = false
    @Published var uninstallResult: UninstallResult?
    @Published var showingTrashConfirmation = false
    @Published var showingAccessIssues = false
    @Published var alertMessage: String?
    @Published private(set) var recoverableTrashBytes: Int64 = 0
    let scanStatus = ScanStatus()

    private let scanner = StorageScanner()
    private let cache = ScanCache()
    private let trashService = TrashService()
    private let applicationDiscovery = ApplicationDiscoveryService()
    let gameAdapter = LocalGameLibraryAdapter()
    @Published var managedGames: [ManagedGame] = []
    @Published private(set) var applicationsByName: [InstalledApplication] = []
    @Published private(set) var applicationsLargest: [InstalledApplication] = []
    @Published private(set) var applicationsSmallest: [InstalledApplication] = []
    @Published private(set) var gamesByName: [ManagedGame] = []
    @Published private(set) var gamesLargest: [ManagedGame] = []
    @Published private(set) var gamesSmallest: [ManagedGame] = []
    @Published var installationSizes: [String: InstallationSize] = [:]
    @Published var gameIcons: [String: NSImage] = [:]
    @Published private(set) var applicationIconRevision = UUID()
    private var applicationsTask: Task<Void, Never>?
    private var applicationsGeneration = UUID()
    private var volumeRefreshTask: Task<Void, Never>?
    private var volumeRefreshGeneration = UUID()
    private let uninstallService = UninstallService()
    private var scanTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    let iconCache = SessionIconCache()
    @Published var applicationIcons: [String: NSImage] = [:]
    @Published var bubbleFrame: FolderBubbleFrame?
    @Published var bubbleIsLoading = false
    @Published var explorerHoveredID: String?
    @Published var cleanupSelectedIDs: Set<String> = []
    @Published var cleanupActionMessage = ""
    private var maximumBubbles = 24
    private var bubbleAvailableDiameter = Double.infinity
    private var explorerHistory: [URL] = []
    private var explorerHistoryPosition = -1
    private var navigatingHistory = false
    @Published var bubbleMessage = "Préparation du graphique…"
    @Published var bubbleRemainderPaths: Set<String>?
    private var bubbleTask: Task<Void, Never>?
    private var bubbleGeneration = UUID()
    private var autoScanAttempts: Set<String> = []
    private var browseGeneration = UUID()
    private var trashRefreshTask: Task<Void, Never>?
    private var trashNeedsRefresh = false
    private var trashCheckedAt = Date.distantPast
    private var trashAuthorization: TrashEmptyAuthorization?
    private var directoryIndexStore: DirectoryIndexStore?
    private var scanGeneration = UUID()
    private var requestedTrashPreflights: [TrashPreflightResult] = []
    private var trashRequestGeneration = UUID()
    private var encounteredApplicationURLs: Set<URL> = []

    init() {
        let mounted = StorageService.mountedVolumes()
        volumes = mounted
        selectedVolumeID = mounted.first(where: { $0.url.path == "/" })?.id ?? mounted.first?.id ?? "/"
    }

    var selectedVolume: StorageVolume? { volumes.first { $0.id == selectedVolumeID } }

    var displayedCategoryReport: CategoryReport? {
        if isScanning, let liveSummary { return liveSummary.categoryReport }
        return snapshot?.categoryReport
    }

    var displayedCleanupReport: CleanupReport? { validatedCleanupReport ?? snapshot?.cleanupReport }

    var selectedItems: [FileSystemItem] {
        if sidebar == .explorer && explorerPendingDirectory != nil { return [] }
        return SelectionNormalizer.normalize(presentationItems.filter { selectedIDs.contains($0.id) })
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }
    var trashConfirmationItems: [FileSystemItem] { requestedTrashPreflights.map(\.item) }
    var trashConfirmationBytes: Int64 { trashConfirmationItems.reduce(0) { $0 + $1.allocatedSize } }

    private var presentationItems: [FileSystemItem] {
        sidebar == .explorer ? explorerVisibleItems : visibleItems
    }

    var explorerVisibleItems: [FileSystemItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ordered: [FileSystemItem]
        if let prepared = explorerSortedSnapshot, prepared.items == explorerItems {
            switch sort { case .allocated: ordered = prepared.largest; case .smallest: ordered = prepared.smallest; case .name: ordered = prepared.names; default: ordered = explorerItems.sorted(by: comparator) }
        } else { ordered = explorerItems.sorted(by: comparator) }
        return ordered.filter { item in
            (bubbleRemainderPaths == nil || bubbleRemainderPaths!.contains(item.url.path)) &&
            (kindFilter == .all || item.isDirectory == (kindFilter == .folders)) &&
            item.allocatedSize >= sizeFilter.rawValue &&
            (categoryFilter == nil || item.category == categoryFilter) &&
            (query.isEmpty || item.name.lowercased().contains(query) || item.url.path.lowercased().contains(query))
        }
    }

    var visibleItems: [FileSystemItem] {
        guard let snapshot else { return [] }
        let base: [FileSystemItem]
        if let currentDirectory {
            base = snapshot.directoryContents[currentDirectory.standardizedFileURL.path] ?? []
        } else {
            switch sidebar ?? .overview {
            case .largestFolders: base = snapshot.topDirectories
            case .largestFiles: base = snapshot.topFiles
            default: base = Array((snapshot.topFiles + snapshot.topDirectories).sorted { $0.allocatedSize > $1.allocatedSize }.prefix(500))
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = base.filter { item in
            (kindFilter == .all || item.isDirectory == (kindFilter == .folders)) &&
            item.allocatedSize >= sizeFilter.rawValue &&
            (categoryFilter == nil || item.category == categoryFilter) &&
            (query.isEmpty || item.name.lowercased().contains(query) || item.url.path.lowercased().contains(query) || item.fileExtension.contains(query.replacingOccurrences(of: ".", with: "")))
        }
        return filtered.sorted(by: comparator)
    }

    private var comparator: (FileSystemItem, FileSystemItem) -> Bool {
        switch sort {
        case .allocated: { $0.allocatedSize > $1.allocatedSize }
        case .smallest: { $0.allocatedSize < $1.allocatedSize }
        case .name: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .type: { $0.category.rawValue < $1.category.rawValue }
        case .date: { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .path: { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }
    }

    func filteredForDisplay(_ items: [FileSystemItem]) -> [FileSystemItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            item.allocatedSize >= sizeFilter.rawValue &&
            (kindFilter == .all || item.isDirectory == (kindFilter == .folders)) &&
            (query.isEmpty || item.name.lowercased().contains(query) || item.url.path.lowercased().contains(query))
        }.sorted(by: comparator)
    }

    func startScan() {
        LocalDiagnostics.shared.record(action: "analyse du stockage")
        guard !isPreviewMode, let volume = selectedVolume, !isScanning, !operationsAreBusy else { return }
        let previousCount: Int?
        if let previous = snapshot, previous.root.standardizedFileURL.path == volume.url.standardizedFileURL.path, previous.completedAt != nil {
            previousCount = previous.progress.filesScanned + previous.progress.directoriesScanned
        } else {
            previousCount = nil
        }
        explorerViewCache.clear()
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        selectedIDs.removeAll()
        if explorerCategoryContext != nil { categoryFilter = nil }
        explorerCategoryContext = nil
        autoScanAttempts.insert(volume.id)
        if sidebar != .explorer { currentDirectory = nil }
        else if currentDirectory == nil { currentDirectory = volume.url }
        if sidebar == .explorer {
            explorerIssues = []
            explorerIsLoading = false
        }
        isScanning = true
        liveSummary = nil
        validatedCleanupReport = nil
        duplicateReport = nil
        duplicateSelectedIDs.removeAll()
        scanStatus.begin(expectedItemCount: previousCount)
        snapshot = nil
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await event in scanner.scan(root: volume.url, volumeID: volume.id) {
                guard !Task.isCancelled, generation == scanGeneration, selectedVolumeID == volume.id else { break }
                switch event {
                case .progress(let value): scanStatus.update(value)
                case .live(let value):
                    liveSummary = value
                    scanStatus.update(value.progress)
                    if sidebar == .explorer, let context = explorerCategoryContext {
                        presentCategoryReport(value.categoryReport, category: context.category, volumeID: value.volumeID)
                    } else if sidebar == .explorer, explorerPendingDirectory == nil,
                       currentDirectory?.standardizedFileURL.path == volume.url.standardizedFileURL.path,
                       !value.rootItems.isEmpty {
                        explorerItems = value.rootItems
                    }
                case .finalizing(let value): scanStatus.update(value, finalizing: true)
                case .update(let value): snapshot = value
                case .completed(let value):
                    snapshot = value
                    scanStatus.update(value.progress)
                    isScanning = false
                    try? await cache.save(value)
                    guard generation == scanGeneration, selectedVolumeID == volume.id else { break }
                    if sidebar == .explorer, let context = explorerCategoryContext {
                        presentCategoryReport(value.categoryReport, category: context.category, volumeID: value.volumeID)
                    } else if sidebar == .explorer {
                        explorerViewCache.clear(); loadExplorerDirectory(explorerPendingDirectory ?? currentDirectory ?? volume.url)
                    }
                    if pendingCleanupAnalysis { calculateCleanup() }
                case .cancelled(let value):
                    snapshot = value
                    scanStatus.update(value.progress)
                    isScanning = false
                    if sidebar == .explorer, let context = explorerCategoryContext {
                        presentCategoryReport(value.categoryReport, category: context.category, volumeID: value.volumeID)
                    }
                }
            }
            if generation == scanGeneration, selectedVolumeID == volume.id {
                isScanning = false
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration = UUID()
        isScanning = false
        pendingCleanupAnalysis = false
    }

    func selectVolume(id: String) {
        guard volumes.contains(where: { $0.id == id }), !operationsAreBusy || isScanning else { return }
        if id == selectedVolumeID {
            if sidebar == .explorer { openExplorerStorage(id: id) }
            return
        }
        if isScanning { stopScan() }
        let generation = UUID()
        scanGeneration = generation
        explorerViewCache.clear()
        selectedVolumeID = id
        explorerHistory = []; explorerHistoryPosition = -1
        cleanupSelectedIDs.removeAll(); cleanupActionMessage = ""
        selectedIDs.removeAll()
        currentDirectory = nil
        browseTask?.cancel()
        browseGeneration = UUID()
        explorerItems = []
        explorerIssues = []
        encounteredApplicationURLs.removeAll()
        trashRequestGeneration = UUID()
        requestedTrashPreflights = []
        showingTrashConfirmation = false
        explorerCategoryContext = nil
        directoryIndexStore = nil
        bubbleTask?.cancel(); bubbleGeneration = UUID(); bubbleFrame = nil
        bubbleMessage = "Préparation du graphique…"
        snapshot = nil
        liveSummary = nil
        validatedCleanupReport = nil
        cleanupTask?.cancel()
        cleanupIsAnalyzing = false
        cancelDuplicateAnalysis()
        Task { [weak self] in
            guard let self else { return }
            let restored = try? await cache.load(volumeID: id)
            guard !Task.isCancelled,
                  generation == scanGeneration,
                  selectedVolumeID == id,
                  snapshot == nil,
                  restored?.volumeID == id else { return }
            snapshot = restored
        }
        if sidebar == .explorer { openExplorerStorage(id: id) }
    }

    func refreshVolumes() {
        refreshTrashSummary()
        volumeRefreshTask?.cancel()
        let generation = UUID(); volumeRefreshGeneration = generation
        volumeRefreshTask = Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) { StorageService.mountedVolumes() }.value
            guard let self, !Task.isCancelled, generation == volumeRefreshGeneration else { return }
            applyRefreshedVolumes(refreshed)
        }
    }

    private func applyRefreshedVolumes(_ refreshed: [StorageVolume]) {
        let previousMounts = Set(volumes.map { $0.id + "|" + $0.url.path })
        if previousMounts != Set(refreshed.map { $0.id + "|" + $0.url.path }) { explorerViewCache.clear() }
        volumes = refreshed
        if !refreshed.contains(where: { $0.id == selectedVolumeID }) {
            explorerViewCache.clear()
            stopScan(); browseTask?.cancel(); browseGeneration = UUID()
            bubbleTask?.cancel(); bubbleGeneration = UUID(); bubbleFrame = nil
            currentDirectory = nil; explorerItems = []; snapshot = nil; liveSummary = nil
            choosingExplorerStorage = true
            storageChoiceMessage = "Le stockage actif a été déconnecté. Choisissez un autre stockage."
        }
    }

    func enterExplorer() {
        refreshVolumes()
        let local = volumes.filter(\.isLocal)
        if local.count == 1, let volume = local.first { openExplorerStorage(id: volume.id) }
        else { showExplorerStorages() }
    }

    func showExplorerStorages() {
        browseTask?.cancel(); browseGeneration = UUID()
        bubbleTask?.cancel(); bubbleGeneration = UUID()
        explorerIsLoading = false; bubbleIsLoading = false
        choosingExplorerStorage = true
        storageChoiceMessage = volumes.contains(where: \.isLocal) ? "Choisissez un stockage pour ouvrir sa racine." : "Aucun stockage local accessible. Branchez un disque puis actualisez."
    }

    func openExplorerStorage(id: String) {
        guard !operationsAreBusy || isScanning, let volume = volumes.first(where: { $0.id == id && $0.isLocal }) else { return }
        if id != selectedVolumeID { selectVolume(id: id); return }
        choosingExplorerStorage = false
        explorerHistory = []; explorerHistoryPosition = -1
        resetSectionFilters(); resetExplorerTemporaryList()
        storageChoiceMessage = "Racine ouverte · historique et filtres de l’explorateur réinitialisés."
        currentDirectory = volume.url
        loadExplorerRoot()
    }

    func installationSize(at url: URL, declaredBytes: Int64? = nil) -> InstallationSize {
        installationSizes[url.standardizedFileURL.path] ?? InstallationSize(bytes: declaredBytes, state: declaredBytes == nil ? .calculating : .declared)
    }

    func loadApplications() {
        if isPreviewMode { return }
        applicationsTask?.cancel()
        let generation = UUID(); applicationsGeneration = generation
        applicationsAreLoading = true
        let visibleApplications = explorerItems.filter { $0.isDirectory && $0.fileExtension == "app" }.map(\.url)
        let additional = Array(encounteredApplicationURLs.union(visibleApplications))
        applicationsTask = Task { [weak self] in
            guard let self else { return }
            async let foundApps = applicationDiscovery.discover(additionalURLs: additional)
            async let foundGames = gameAdapter.detect()
            let (discovered, games) = await (foundApps, foundGames)
            guard !Task.isCancelled, applicationsGeneration == generation else { return }
            applications = discovered
            managedGames = games
            let paths = Set((discovered.map(\.bundleURL) + games.map(\.installURL)).map { $0.standardizedFileURL.path })
            installationSizes = installationSizes.filter { paths.contains($0.key) }
            applicationIcons = applicationIcons.filter { paths.contains($0.key) }
            gameIcons = gameIcons.filter { key, _ in games.contains { $0.id == key } }
            await prepareInstallationOrder(generation: generation)
            guard !Task.isCancelled, applicationsGeneration == generation else { return }
            applicationIconRevision = UUID()
            applicationsAreLoading = false
            // Both inventories share ONE bounded group, never four simultaneous directory walks.
            await InstallationSizeService.measureAll(discovered.map(\.bundleURL) + games.map(\.installURL)) { [weak self] batch in
                await self?.publishInstallationSizes(batch, generation: generation)
            }
        }
    }

    func loadApplicationIcon(_ application: InstalledApplication) async {
        let image = await iconCache.load(for: application.bundleURL, version: application.version)
        guard !Task.isCancelled, applications.contains(where: { $0.id == application.id && $0.bundleIdentity == application.bundleIdentity && $0.version == application.version }) else { return }
        applicationIcons[application.bundleURL.path] = image
    }

    func loadGameIcon(_ game: ManagedGame) async {
        let root = game.installURL
        let bundle = await Task.detached(priority: .utility) { () -> URL? in
            if root.pathExtension == "app" { return root }
            return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]))?.prefix(100).first {
                $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            }
        }.value
        guard let bundle else { return }
        let image = await iconCache.load(for: bundle)
        guard !Task.isCancelled, managedGames.contains(where: { $0.id == game.id && $0.manifestIdentity == game.manifestIdentity }) else { return }
        gameIcons[game.id] = image
    }

    private func publishInstallationSizes(_ batch: [String: InstallationSize], generation: UUID) async {
        guard applicationsGeneration == generation else { return }
        installationSizes.merge(batch) { _, new in new }
        await prepareInstallationOrder(generation: generation)
    }

    private func prepareInstallationOrder(generation: UUID) async {
        let apps = applications, games = managedGames, sizes = installationSizes
        let prepared = await Task.detached(priority: .utility) {
            func before(_ left: Int64?, _ right: Int64?, small: Bool) -> Bool? {
                if (left == nil) != (right == nil) { return left != nil }
                if left != right { return small ? (left ?? 0) < (right ?? 0) : (left ?? 0) > (right ?? 0) }
                return nil
            }
            func appOrder(_ small: Bool) -> [InstalledApplication] {
                apps.sorted { before(sizes[$0.bundleURL.path]?.bytes, sizes[$1.bundleURL.path]?.bytes, small: small)
                    ?? ($0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending) }
            }
            func gameOrder(_ small: Bool) -> [ManagedGame] {
                games.sorted { before(sizes[$0.installURL.path]?.bytes ?? $0.estimatedBytes, sizes[$1.installURL.path]?.bytes ?? $1.estimatedBytes, small: small)
                    ?? ($0.name.localizedStandardCompare($1.name) == .orderedAscending) }
            }
            return (apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }, appOrder(false), appOrder(true),
                games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, gameOrder(false), gameOrder(true))
        }.value
        guard applicationsGeneration == generation else { return }
        (applicationsByName, applicationsLargest, applicationsSmallest, gamesByName, gamesLargest, gamesSmallest) = prepared
    }

    func prepareUninstall(_ application: InstalledApplication) {
        showingUninstall = true
        uninstallIsWorking = true
        uninstallPlan = nil
        uninstallResult = nil
        uninstallSelectedIDs = []
        Task { [weak self] in
            guard let self else { return }
            let plan = await uninstallService.makePlan(for: application)
            uninstallPlan = plan
            uninstallSelectedIDs = plan.defaultCandidateIDs
            uninstallIsWorking = false
        }
    }

    func prepareUninstall(item: FileSystemItem) {
        guard item.isDirectory, item.fileExtension == "app" else { return }
        if let known = applications.first(where: { $0.bundleURL.standardizedFileURL.path == item.url.standardizedFileURL.path }) {
            prepareUninstall(known)
        } else {
            showingUninstall = true
            uninstallIsWorking = true
            uninstallPlan = nil
            uninstallResult = nil
            Task { [weak self] in
                guard let self else { return }
                guard let discovered = await applicationDiscovery.application(at: item.url) else {
                    showingUninstall = false
                    uninstallIsWorking = false
                    alertMessage = "Cette application n’a pas pu être identifiée de façon sûre."
                    return
                }
                prepareUninstall(discovered)
            }
        }
    }

    func performUninstall(requestQuitIfRunning: Bool = true) {
        LocalDiagnostics.shared.record(action: "désinstallation d’application")
        guard let plan = uninstallPlan, plan.canProceed, !uninstallIsWorking else { return }
        uninstallIsWorking = true
        Task { [weak self] in
            guard let self else { return }
            let result = await uninstallService.uninstall(
                plan,
                selectedCandidateIDs: uninstallSelectedIDs,
                requestQuitIfRunning: requestQuitIfRunning
            )
            uninstallResult = result
            uninstallIsWorking = false
            if [.succeeded, .partial].contains(result.status) {
                refreshTrashSummary(force: true)
                recoverableTrashBytes += result.recoverableBytesUpperBound
                let trashedPaths = Set(
                    ([result.bundleResult].compactMap { $0 } + result.associatedResults)
                        .filter { $0.status == .trashed }
                        .map { $0.originalURL.standardizedFileURL.path }
                )
                let removedItems = plan.candidates.compactMap { candidate -> FileSystemItem? in
                    guard trashedPaths.contains(candidate.url.standardizedFileURL.path) else { return nil }
                    return FileSystemItem(
                        url: candidate.url,
                        logicalSize: candidate.allocatedBytesUpperBound,
                        allocatedSize: candidate.allocatedBytesUpperBound,
                        isDirectory: candidate.isDirectory,
                        isPackage: candidate.isPackage,
                        category: candidate.group == .applicationBundle ? .application : .applicationData,
                        safety: .review
                    )
                }
                if !removedItems.isEmpty {
                    removeFromSnapshot(removedItems)
                    if let directoryIndexStore {
                        for item in removedItems where item.isDirectory {
                            _ = try? await directoryIndexStore.removeSubtree(at: item.url.path)
                        }
                    }
                    selectedIDs.subtract(trashedPaths)
                    if sidebar == .explorer, let directory = currentDirectory {
                        loadExplorerDirectory(directory)
                    }
                }
                refreshVolumes()
                loadApplications()
                validatedCleanupReport = nil
                duplicateReport = nil
            }
        }
    }

    func prepareEmptyTrash() {
        guard !trashInventoryIsLoading, emptyTrashStep != .running else { return }
        showingEmptyTrash = true
        emptyTrashStep = .inventory
        trashInventory = nil
        emptyTrashResult = nil
        emptyTrashConfirmation = ""
        trashInventoryIsLoading = true
        Task { [weak self] in
            guard let self else { return }
            let inventory = await trashService.inventoryTrash(volumes: volumes)
            trashInventory = inventory
            trashSummary = inventory
            trashInventoryIsLoading = false
        }
    }

    func emptyTrashPermanently() {
        guard !operationsAreBusy, let inventory = trashInventory else { return }
        trashAuthorization = TrashEmptyAuthorization.confirm(inventory)
        guard let authorization = trashAuthorization else { return }
        trashAuthorization = nil
        emptyTrashStep = .running
        Task { [weak self] in
            guard let self else { return }
            let result = await trashService.emptyTrash(inventory, authorization: authorization, volumes: volumes)
            emptyTrashResult = result
            emptyTrashStep = .result
            refreshTrashSummary(force: true)
            recoverableTrashBytes = max(0, recoverableTrashBytes - result.deletedBytesUpperBound)
            refreshVolumes()
            validatedCleanupReport = nil
            duplicateReport = nil
            if let old = snapshot {
                snapshot = ScanSnapshot(
                    root: old.root,
                    progress: old.progress,
                    topFiles: old.topFiles,
                    topDirectories: old.topDirectories,
                    directoryContents: old.directoryContents,
                    issues: old.issues,
                    cleanupReport: nil,
                    completedAt: old.completedAt,
                    scanID: old.scanID,
                    volumeID: old.volumeID,
                    indexVersion: old.indexVersion,
                    categoryReport: CategoryReport(
                        summaries: old.categoryReport.summaries,
                        identifiedLogicalBytes: old.categoryReport.identifiedLogicalBytes,
                        identifiedAllocatedBytes: old.categoryReport.identifiedAllocatedBytes,
                        permissionErrors: old.categoryReport.permissionErrors,
                        isComplete: false,
                        generatedAt: Date()
                    )
                )
            }
        }
    }

    private var pendingCleanupAnalysis = false

    func calculateCleanup() {
        guard !cleanupIsAnalyzing else { return }
        guard let report = snapshot?.cleanupReport else {
            pendingCleanupAnalysis = true
            if !isScanning { startScan() }
            return
        }
        pendingCleanupAnalysis = false
        cleanupTask?.cancel()
        cleanupIsAnalyzing = true
        cleanupProgress = CleanupAnalysisProgress(phase: .preparing, completedUnits: 0, totalUnits: 1)
        let service = CleanupAnalysisService()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            for await event in service.analyze(report) {
                guard !Task.isCancelled else { break }
                switch event {
                case .progress(let progress): cleanupProgress = progress
                case .completed(let value):
                    validatedCleanupReport = value
                    cleanupIsAnalyzing = false
                    cleanupProgress = nil
                case .cancelled:
                    cleanupIsAnalyzing = false
                    cleanupProgress = nil
                }
            }
            cleanupIsAnalyzing = false
        }
    }

    func cancelCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupIsAnalyzing = false
        cleanupProgress = nil
        pendingCleanupAnalysis = false
    }

    func startDuplicateAnalysis(minimumSize: Int64 = 1, directory: URL? = nil) {
        guard let volume = selectedVolume, !duplicateIsAnalyzing else { return }
        resetSectionFilters()
        duplicateTask?.cancel()
        duplicateReport = nil
        duplicateError = nil
        duplicateSelectedIDs.removeAll()
        duplicateIsAnalyzing = true
        duplicateProgress = DuplicateAnalysisProgress()
        let service = DuplicateAnalysisService()
        duplicateTask = Task { [weak self] in
            guard let self else { return }
            for await event in service.events(root: directory ?? volume.url, minimumSize: minimumSize) {
                guard !Task.isCancelled, selectedVolumeID == volume.id else { break }
                switch event {
                case .progress(let progress): duplicateProgress = progress
                case .completed(let report):
                    duplicateReport = report
                    duplicateProgress = report.progress
                    duplicateIsAnalyzing = false
                case .cancelled(let progress):
                    duplicateProgress = progress
                    duplicateIsAnalyzing = false
                case .failed(let message):
                    duplicateError = message
                    duplicateIsAnalyzing = false
                }
            }
            duplicateIsAnalyzing = false
        }
    }

    func cancelDuplicateAnalysis() {
        duplicateTask?.cancel()
        duplicateTask = nil
        duplicateIsAnalyzing = false
    }

    func setDuplicateSelected(_ file: DuplicateFile, in group: DuplicateGroup, selected: Bool) {
        if selected {
            let selectedInGroup = group.files.filter { duplicateSelectedIDs.contains($0.id) }.count
            guard selectedInGroup < group.files.count - group.minimumCopiesToKeep else {
                alertMessage = "Conservez au moins une copie de chaque groupe de doublons."
                return
            }
            duplicateSelectedIDs.insert(file.id)
        } else {
            duplicateSelectedIDs.remove(file.id)
        }
    }

    func trashSelectedDuplicates() {
        guard let report = duplicateReport else { return }
        let selectedIDs = duplicateSelectedIDs
        guard !selectedIDs.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let service = DuplicateAnalysisService()
                var validatedItems: [FileSystemItem] = []
                for group in report.groups {
                    let groupSelection = Set(group.files.map(\.id).filter { selectedIDs.contains($0) })
                    guard !groupSelection.isEmpty else { continue }
                    validatedItems.append(contentsOf: try await service.validatedTrashItems(
                        in: group, selectedFileIDs: groupSelection
                    ))
                }
                guard !Task.isCancelled, !validatedItems.isEmpty else { return }
                requestTrash(items: validatedItems)
            } catch {
                duplicateError = error.localizedDescription
                alertMessage = "Les doublons ont changé depuis l’analyse : \(error.localizedDescription)"
            }
        }
    }

    func restoreLastScan() async {
        guard snapshot == nil else { return }
        let volumeID = selectedVolumeID
        let generation = scanGeneration
        let restored = try? await cache.load(volumeID: volumeID)
        guard !Task.isCancelled,
              generation == scanGeneration,
              selectedVolumeID == volumeID,
              snapshot == nil,
              restored?.volumeID == volumeID else { return }
        snapshot = restored
    }

    func open(_ item: FileSystemItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: FileSystemItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func copyPath(_ item: FileSystemItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }

    func copyName(_ item: FileSystemItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.name, forType: .string)
    }

    func activate(_ item: FileSystemItem) {
        guard explorerPendingDirectory == nil || sidebar != .explorer else { return }
        if item.isDirectory {
            if sidebar == .explorer {
                navigationAnchor = .center
                loadExplorerDirectory(item.url)
            } else {
                currentDirectory = item.url
                selectedIDs.removeAll()
            }
        } else { reveal(item) }
    }

    func showPackageContents(_ item: FileSystemItem) {
        guard item.isDirectory, item.isPackage else { return }
        loadExplorerDirectory(item.url, allowPackageTraversal: true)
    }

    func loadExplorerRoot() {
        guard let volume = selectedVolume else { return }
        sidebar = .explorer
        navigationBack = true; navigationAnchor = .center
        loadExplorerDirectory(volume.url)
    }

    func refreshExplorerView() {
        explorerViewCache.clear()
        guard let destination = explorerPendingDirectory ?? currentDirectory ?? selectedVolume?.url else { return }
        loadExplorerDirectory(destination)
    }

    func loadExplorerDirectory(_ directory: URL, allowPackageTraversal: Bool = false) {
        resetExplorerTemporaryList()
        if isPreviewMode { return }
        guard let volume = selectedVolume else { return }
        saveExplorerView()
        browseTask?.cancel(); bubbleTask?.cancel(); bubbleGeneration = UUID()
        let generation = UUID(); browseGeneration = generation
        let directory = directory.standardizedFileURL
        let key = explorerCacheKey(directory)
        let cached = explorerViewCache.get(key)
        let back = navigationBack
        let recordHistory = !navigatingHistory
        navigationBack = false
        let maximum = maximumBubbles, diameter = bubbleAvailableDiameter
        let layout = explorerLayoutKey
        explorerCategoryContext = nil
        explorerVisited = 0; explorerIssues = []
        explorerPendingDirectory = directory
        explorerIsLoading = true; bubbleIsLoading = false; explorerLoaderVisible = false
        loaderTask?.cancel()
        if cached == nil {
            loaderTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, browseGeneration == generation, explorerIsLoading else { return }
                explorerLoaderVisible = true
            }
        }
        do {
            let store = try DirectoryIndexStore(volumeID: volume.id, root: volume.url)
            directoryIndexStore = store
            let browser = DirectoryBrowserService(volumeID: volume.id, root: volume.url, indexStore: store)
            browseTask = Task { [weak self] in
                guard let self else { return }
                @MainActor func isCurrent() -> Bool { !Task.isCancelled && selectedVolumeID == volume.id && browseGeneration == generation }
                defer { if browseGeneration == generation { explorerIsLoading = false; explorerLoaderVisible = false; explorerPendingDirectory = nil; loaderTask?.cancel() } }
                if let cached {
                    publishExplorerView(cached, directory: directory, back: back, animate: true, recordHistory: recordHistory)
                }
                var pending: [FileSystemItem] = []
                var issues: [ScanIssue] = []
                for await event in browser.browse(directory: directory, options: DirectoryBrowseOptions(includeHidden: true, batchSize: 256, allowPackageTraversal: allowPackageTraversal)) {
                    guard isCurrent() else { return }
                    switch event {
                    case .started: break
                    case .batch(_, let items): pending.append(contentsOf: items); explorerVisited = pending.count
                    case .issue(let issue): if issues.count < 200 { issues.append(issue) }
                    case .completed:
                        if !issues.isEmpty && pending.isEmpty {
                            explorerIssues = issues; bubbleMessage = issues.first?.message ?? "Dossier inaccessible."
                            if cached != nil { explorerItems = []; bubbleFrame = nil }
                            return
                        }
                        let partial = isScanning || snapshot?.completedAt == nil || !issues.isEmpty
                        do {
                            let frame = try await store.bubbleFrame(forPath: directory.path, partial: partial, items: pending, maximumVisible: maximum, availableDiameter: diameter)
                            let preparedItems = pending
                            let view = await Task.detached { ExplorerViewSnapshot(items: preparedItems, frame: frame, layout: layout, selection: cached?.selection ?? [], scroll: cached?.scroll ?? .nan) }.value
                            guard isCurrent() else { return }
                            explorerViewCache.put(key, view)
                            explorerIssues = issues
                            if cached?.items != view.items || cached?.layout != layout { publishExplorerView(view, directory: directory, back: back, animate: cached == nil, recordHistory: recordHistory) }
                            else { bubbleFrame = frame }
                            if frame.totalBytes == nil, !isScanning, !operationsAreBusy, !autoScanAttempts.contains(volume.id) { autoScanAttempts.insert(volume.id); startScan() }
                        } catch { if isCurrent() { bubbleMessage = error.localizedDescription } }
                    case .cancelled: return
                    }
                }
            }
        } catch {
            explorerIsLoading = false; explorerPendingDirectory = nil; explorerLoaderVisible = false; loaderTask?.cancel()
            bubbleMessage = error.localizedDescription
        }
    }

    func requestTrashSelection() {
        guard explorerPendingDirectory == nil || sidebar != .explorer else { return }
        requestTrash(items: selectedItems)
    }

    func requestTrash(items: [FileSystemItem]) {
        guard explorerPendingDirectory == nil || sidebar != .explorer else { return }
        let generation = UUID()
        trashRequestGeneration = generation
        requestedTrashPreflights = []
        let normalized = SelectionNormalizer.normalize(items)
        guard !normalized.isEmpty else { return }
        let applications = normalized.filter { $0.isDirectory && $0.fileExtension == "app" }
        if applications.count == 1, normalized.count == 1 {
            prepareUninstall(item: applications[0])
            return
        }
        if !applications.isEmpty {
            alertMessage = "Une sélection contenant une application ne peut pas utiliser la suppression générique. Désinstallez chaque application séparément."
            return
        }
        if normalized.contains(where: { !$0.isTrashable }) {
            alertMessage = "La sélection contient un élément système protégé."
        } else {
            Task { [weak self] in
                guard let self else { return }
                let preflights = await trashService.preflight(normalized)
                guard generation == trashRequestGeneration else { return }
                let failures = preflights.filter { !$0.isReady }
                guard failures.isEmpty else {
                    alertMessage = "La suppression a été bloquée avant confirmation.\n"
                        + failures.prefix(3).compactMap(\.errorDescription).joined(separator: "\n")
                    return
                }
                requestedTrashPreflights = preflights
                showingTrashConfirmation = true
            }
        }
    }

    func confirmTrash() {
        let preflights = requestedTrashPreflights
        let items = preflights.map(\.item)
        guard !preflights.isEmpty, !trashIsWorking else { return }
        trashIsWorking = true
        showingTrashConfirmation = false
        requestedTrashPreflights = []
        trashRequestGeneration = UUID()
        Task {
            defer { trashIsWorking = false }
            let results = await trashService.trashWithResults(preflights)
            let trashedPaths = Set(results.filter { $0.status == .trashed }.map { $0.originalURL.standardizedFileURL.path })
            let succeeded = items.filter { trashedPaths.contains($0.url.standardizedFileURL.path) }
            if !succeeded.isEmpty {
                refreshTrashSummary(force: true)
                recoverableTrashBytes += results.reduce(0) {
                    $0 + ($1.status == .trashed ? $1.allocatedBytesUpperBound : 0)
                }
                removeFromSnapshot(succeeded)
                if let directoryIndexStore {
                    for item in succeeded where item.isDirectory {
                        _ = try? await directoryIndexStore.removeSubtree(at: item.url.path)
                    }
                }
                selectedIDs.removeAll()
                duplicateSelectedIDs.removeAll()
                duplicateReport = nil
                validatedCleanupReport = nil
                refreshVolumes()
                if sidebar == .explorer, let directory = currentDirectory {
                    loadExplorerDirectory(directory)
                }
            }
            let failures = results.filter { $0.status == .failed }
            alertMessage = "\(succeeded.count) élément(s) dans la Corbeille, \(failures.count) échec(s). L’espace sera libéré après vidage de la Corbeille.\n" + failures.prefix(3).compactMap(\.errorDescription).joined(separator: "\n")
        }
    }

    private func removeFromSnapshot(_ items: [FileSystemItem]) {
        guard let old = snapshot else { return }
        let normalized = SelectionNormalizer.normalize(items)
        let removed = Set(normalized.map(\.id))
        let removedDirectoryPaths = normalized.filter(\.isDirectory).map { $0.url.standardizedFileURL.path }
        func wasRemoved(_ item: FileSystemItem) -> Bool {
            let path = item.url.standardizedFileURL.path
            return removed.contains(item.id) || removedDirectoryPaths.contains(where: { path.hasPrefix($0 + "/") })
        }
        var directories = old.topDirectories
        var contents = old.directoryContents
        for item in normalized {
            var ancestor = item.url.deletingLastPathComponent().standardizedFileURL
            while ancestor.path.hasPrefix(old.root.path) {
                if let index = directories.firstIndex(where: { $0.url.standardizedFileURL.path == ancestor.path }) {
                    directories[index].allocatedSize = max(0, directories[index].allocatedSize - item.allocatedSize)
                    directories[index].logicalSize = max(0, directories[index].logicalSize - item.logicalSize)
                }
                contents[ancestor.path]?.removeAll { removed.contains($0.id) }
                if ancestor.path == old.root.path { break }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
            if item.isDirectory {
                contents = contents.filter { key, _ in key != item.url.path && !key.hasPrefix(item.url.path + "/") }
            }
        }
        snapshot = ScanSnapshot(
            root: old.root,
            progress: old.progress,
            topFiles: old.topFiles.filter { !wasRemoved($0) },
            topDirectories: directories.filter { !wasRemoved($0) }.sorted { $0.allocatedSize > $1.allocatedSize },
            directoryContents: contents.mapValues { $0.filter { !wasRemoved($0) } },
            issues: old.issues,
            completedAt: old.completedAt,
            scanID: old.scanID,
            volumeID: old.volumeID,
            indexVersion: old.indexVersion,
            categoryReport: CategoryReport(
                summaries: old.categoryReport.summaries,
                identifiedLogicalBytes: old.categoryReport.identifiedLogicalBytes,
                identifiedAllocatedBytes: old.categoryReport.identifiedAllocatedBytes,
                permissionErrors: old.categoryReport.permissionErrors,
                isComplete: false,
                generatedAt: Date()
            )
        )
        if let currentDirectory {
            let currentPath = currentDirectory.standardizedFileURL.path
            if removedDirectoryPaths.contains(where: { currentPath == $0 || currentPath.hasPrefix($0 + "/") }) {
                self.currentDirectory = old.root
            }
        }
    }

    func navigate(to url: URL?) {
        if sidebar == .explorer, let url {
            loadExplorerDirectory(url)
        } else {
            currentDirectory = url
            selectedIDs.removeAll()
        }
    }

    func openCategory(_ category: ItemCategory) {
        sort = .allocated
        guard let report = displayedCategoryReport else {
            alertMessage = "Une analyse est nécessaire pour afficher les principaux fichiers de cette catégorie."
            return
        }
        categoryFilter = category
        browseTask?.cancel()
        presentCategoryReport(report, category: category, volumeID: selectedVolumeID)
        sidebar = .explorer
    }

    func refreshCategoryExplorer() {
        guard let context = explorerCategoryContext,
              let report = displayedCategoryReport else { return }
        presentCategoryReport(report, category: context.category, volumeID: selectedVolumeID)
    }

    func exploreCategoryAtRoot() {
        guard let context = explorerCategoryContext, let volume = selectedVolume else { return }
        let category = context.category
        explorerCategoryContext = nil
        categoryFilter = category
        loadExplorerDirectory(volume.url)
    }

    private func presentCategoryReport(_ report: CategoryReport, category: ItemCategory, volumeID: String) {
        guard volumeID == selectedVolumeID else { return }
        let summary = report.summary(for: category)
        let items = knownCategoryItems(summary: summary, volumeID: volumeID)
        currentDirectory = nil
        selectedIDs.removeAll()
        explorerItems = items
        explorerIssues = []
        explorerIsLoading = false
        explorerShowsSmallItems = false
        explorerCategoryContext = ExplorerCategoryContext(
            category: category,
            totalLogicalBytes: summary.logicalBytes,
            totalAllocatedBytes: summary.allocatedBytes,
            totalFileCount: summary.fileCount,
            knownItemCount: items.count,
            knownAllocatedBytes: items.reduce(0) { $0 + $1.allocatedSize },
            reportIsComplete: report.isComplete,
            generatedAt: report.generatedAt
        )
    }

    private func knownCategoryItems(summary: CategorySummary, volumeID: String) -> [FileSystemItem] {
        var candidates = summary.topContributors
        if let snapshot, snapshot.volumeID == volumeID {
            candidates.append(contentsOf: snapshot.topFiles)
            candidates.append(contentsOf: snapshot.directoryContents.values.joined())
        }
        if let liveSummary, liveSummary.volumeID == volumeID {
            candidates.append(contentsOf: liveSummary.rootItems)
        }

        var byPath: [String: FileSystemItem] = [:]
        for item in candidates where !item.isDirectory && item.category == summary.category {
            let path = item.url.standardizedFileURL.path
            if let existing = byPath[path], existing.allocatedSize >= item.allocatedSize { continue }
            byPath[path] = item
        }
        return byPath.values.sorted {
            if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    func examineCleanupItem(_ item: FileSystemItem) {
        if item.isDirectory {
            sidebar = .explorer
            selectedIDs.removeAll()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.loadExplorerDirectory(item.url)
            }
        } else {
            reveal(item)
        }
    }

    func quickLookSelection() {
        guard let item = selectedItems.first, !item.isDirectory else { return }
        QuickLookPresenter.shared.present(item.url)
    }
}

@MainActor
private final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var url: URL?

    func present(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem { url! as NSURL }
}


extension AppModel {
    func ensureBubbleAnalysis() {
        if isPreviewMode { return }
        guard explorerPendingDirectory == nil, !choosingExplorerStorage, explorerShowsGraph, sidebar == .explorer,
              let volume = selectedVolume else { return }
        do {
            let store = try DirectoryIndexStore(volumeID: volume.id, root: volume.url)
            loadBubbleFrame(currentDirectory ?? volume.url, store: store)
        } catch { LocalDiagnostics.shared.record(action: "préparation de l’explorateur", error: error); bubbleMessage = error.localizedDescription }
    }

    private func loadBubbleFrame(_ directory: URL, store: DirectoryIndexStore) {
        bubbleTask?.cancel()
        let generation = UUID(); bubbleGeneration = generation
        let volumeID = selectedVolumeID
        let items = explorerIsLoading ? nil : explorerItems
        let maximum = maximumBubbles
        let diameter = bubbleAvailableDiameter
        bubbleIsLoading = true
        bubbleTask = Task { [weak self] in
            guard let self else { return }
            defer { if bubbleGeneration == generation { bubbleIsLoading = false } }
            do {
                let partial = isScanning || snapshot?.completedAt == nil || (snapshot?.progress.permissionErrors ?? 0) > 0
                let frame = try await store.bubbleFrame(forPath: directory.path, partial: partial, items: items, maximumVisible: maximum, availableDiameter: diameter)
                guard !Task.isCancelled, bubbleGeneration == generation, selectedVolumeID == volumeID, currentDirectory?.path == directory.path else { return }
                bubbleFrame = frame
                if frame.totalBytes == nil {
                    bubbleMessage = isScanning ? "Analyse du disque… Les tailles se précisent en arrière-plan." : "Tailles des dossiers inconnues. Analysez le disque pour compléter le graphique."
                    if !isScanning, !operationsAreBusy, !autoScanAttempts.contains(volumeID) {
                        autoScanAttempts.insert(volumeID); startScan()
                    }
                } else { bubbleMessage = (frame.isPartial ? "Analyse partielle" : "Tailles mesurées") + " · Dossiers et fichiers de ce niveau" }
            } catch is CancellationError { }
            catch { LocalDiagnostics.shared.record(action: "graphique de l’explorateur", error: error); if bubbleGeneration == generation { bubbleFrame = nil; bubbleMessage = "Graphique indisponible. La liste reste accessible." } }
        }
    }

    func resizeBubbleLayout(width: Double, height: Double) {
        let maximum = min(24, max(4, Int(max(200, width) * max(200, height) / 18000)))
        let diameter = max(100, min(width, height) - 12)
        guard maximum != maximumBubbles || abs(diameter - bubbleAvailableDiameter) > 20 else { return }
        bubbleAvailableDiameter = diameter
        maximumBubbles = maximum
        if let directory = currentDirectory, let store = directoryIndexStore { loadBubbleFrame(directory, store: store) }
    }

    func cancelExplorerLoading() {
        browseTask?.cancel(); bubbleTask?.cancel(); browseGeneration = UUID(); bubbleGeneration = UUID()
        loaderTask?.cancel(); explorerLoaderVisible = false; explorerPendingDirectory = nil
        if isScanning { stopScan() }
        if let volume = selectedVolume { autoScanAttempts.insert(volume.id) }
        explorerIsLoading = false; bubbleIsLoading = false
        bubbleMessage = "Chargement annulé. Ouvrez un dossier ou relancez l’analyse pour reprendre."
    }

    func browseHistory(_ direction: Int) {
        if explorerPendingDirectory != nil && direction < 0 { cancelExplorerLoading(); return }
        navigationBack = direction < 0
        let next = explorerHistoryPosition + direction
        guard explorerHistory.indices.contains(next) else { return }
        explorerHistoryPosition = next; navigatingHistory = true
        loadExplorerDirectory(explorerHistory[next]); navigatingHistory = false
    }

    func openBubble(_ node: FolderBubble) {
        if node.isAggregate {
            let known = explorerItems.filter { $0.hasKnownSize && $0.allocatedSize > 0 && !$0.isSymbolicLink }.sorted { $0.allocatedSize == $1.allocatedSize ? $0.id < $1.id : $0.allocatedSize > $1.allocatedSize }
            bubbleRemainderPaths = Set(known.dropFirst(node.skipCount).map(\.id))
            explorerTemporaryList = true; resetSectionFilters()
        } else if node.isDirectory { navigationAnchor = UnitPoint(x: min(1, max(0, (node.circle.x + 1) / 2)), y: min(1, max(0, (node.circle.y + 1) / 2))); loadExplorerDirectory(URL(fileURLWithPath: node.path)) }
        else { selectedIDs = [node.path]; explorerHoveredID = node.path }
    }

    func showDirectFiles() {
        explorerTemporaryList = true; bubbleRemainderPaths = nil
        resetSectionFilters(); kindFilter = .files
    }

    func resetSectionFilters() {
        searchText = ""; sizeFilter = .all; categoryFilter = nil; kindFilter = .all; sort = .allocated
    }

    var selectedCleanupItems: [FileSystemItem] {
        SelectionNormalizer.normalize((displayedCleanupReport?.suggestions.flatMap(\.items) ?? []).filter { cleanupSelectedIDs.contains($0.id) })
    }

    func selectRecognizedTemporaries() {
        guard !operationsAreBusy else { cleanupActionMessage = "Terminez ou annulez l’opération en cours."; return }
        guard let report = displayedCleanupReport else { cleanupActionMessage = "Calcul du nettoyage conseillé…"; calculateCleanup(); return }
        resetSectionFilters()
        let allowed: Set<CleanupSuggestionKind> = [.xcodeDerivedData, .toolCaches, .applicationCaches, .diagnosticReports]
        let items = report.suggestions.filter { allowed.contains($0.id) && $0.confidence == .high && $0.action == .reviewAndTrash }.flatMap(\.items).filter(\.isTrashable)
        cleanupSelectedIDs = Set(SelectionNormalizer.normalize(items).map(\.id))
        cleanupActionMessage = items.isEmpty ? "Aucun temporaire reconnu admissible. Les documents et sauvegardes restent conservés." : "\(cleanupSelectedIDs.count) élément(s) sélectionné(s). Examinez la sélection avant de nettoyer. Les filtres ont été réinitialisés."
    }

    func chooseDuplicateDirectory() {
        guard !operationsAreBusy else { duplicateError = "Terminez ou annulez l’opération en cours."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choisissez un dossier personnel. Les contenus seront comparés ; aucun fichier ne sera supprimé."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        startDuplicateAnalysis(directory: directory)
    }

    var trashSummaryLabel: String {
        guard let summary = trashSummary else { return trashSummaryIsLoading ? "Corbeille · Calcul en cours" : "Corbeille · Indisponible" }
        if summary.items.isEmpty && !summary.issues.isEmpty { return "Corbeille · Indisponible" }
        let partial = !summary.issues.isEmpty || summary.wasCancelled
        return "Corbeille · " + (partial ? "≈ " : "") + ByteCountFormatter.storage.string(fromByteCount: summary.totalAllocatedBytesUpperBound)
    }

    func refreshTrashSummary(force: Bool = false) {
        if isPreviewMode { return }
        if trashRefreshTask != nil { if force { trashNeedsRefresh = true }; return }
        guard force || Date().timeIntervalSince(trashCheckedAt) >= 30 else { return }
        trashSummaryIsLoading = true
        trashRefreshTask = Task { [weak self] in
            guard let self else { return }
            trashSummary = await trashService.inventoryTrash(volumes: volumes)
            trashCheckedAt = Date()
            trashSummaryIsLoading = false
            trashRefreshTask = nil
            if trashNeedsRefresh { trashNeedsRefresh = false; refreshTrashSummary(force: true) }
        }
    }
}
