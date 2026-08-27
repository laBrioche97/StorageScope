import AppKit
import Foundation
import QuickLookUI
import StorageCore
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Vue d’ensemble"
    case explorer = "Explorateur"
    case largestFiles = "Plus gros fichiers"
    case largestFolders = "Plus gros dossiers"
    case categories = "Catégories"
    case cleanup = "Nettoyage conseillé"
    case applications = "Applications"
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
    case allocated = "Taille"
    case name = "Nom"
    case type = "Type"
    case date = "Date"
    case path = "Chemin"
    var id: String { rawValue }
}

enum ExplorerDisplayMode: String, CaseIterable, Identifiable {
    case grid = "Grille"
    case list = "Liste"
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
    @Published var sidebar: SidebarSection? = .overview
    @Published var volumes: [StorageVolume]
    @Published var selectedVolumeID: String
    @Published var snapshot: ScanSnapshot?
    @Published var liveSummary: ScanLiveSummary?
    @Published var isScanning = false
    @Published var searchText = ""
    @Published var sizeFilter: SizeFilter = .all
    @Published var categoryFilter: ItemCategory?
    @Published var sort: ItemSort = .allocated
    @Published var selectedIDs: Set<String> = []
    @Published var currentDirectory: URL?
    @Published var explorerItems: [FileSystemItem] = []
    @Published var explorerIssues: [ScanIssue] = []
    @Published var explorerIsLoading = false
    @Published var explorerDisplayMode: ExplorerDisplayMode = .grid
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
    @Published var trashInventory: TrashInventory?
    @Published var emptyTrashConfirmation = ""
    @Published var emptyTrashResult: EmptyTrashResult?
    @Published var trashInventoryIsLoading = false
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
    private let uninstallService = UninstallService()
    private var scanTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
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
        SelectionNormalizer.normalize(presentationItems.filter { selectedIDs.contains($0.id) })
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }
    var trashConfirmationItems: [FileSystemItem] { requestedTrashPreflights.map(\.item) }
    var trashConfirmationBytes: Int64 { trashConfirmationItems.reduce(0) { $0 + $1.allocatedSize } }

    private var presentationItems: [FileSystemItem] {
        sidebar == .explorer ? explorerVisibleItems : visibleItems
    }

    var explorerVisibleItems: [FileSystemItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return explorerItems.filter { item in
            item.allocatedSize >= sizeFilter.rawValue &&
            (categoryFilter == nil || item.category == categoryFilter) &&
            (query.isEmpty || item.name.lowercased().contains(query) || item.url.path.lowercased().contains(query))
        }.sorted(by: comparator)
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
            item.allocatedSize >= sizeFilter.rawValue &&
            (categoryFilter == nil || item.category == categoryFilter) &&
            (query.isEmpty || item.name.lowercased().contains(query) || item.url.path.lowercased().contains(query) || item.fileExtension.contains(query.replacingOccurrences(of: ".", with: "")))
        }
        return filtered.sorted(by: comparator)
    }

    private var comparator: (FileSystemItem, FileSystemItem) -> Bool {
        switch sort {
        case .allocated: { $0.allocatedSize > $1.allocatedSize }
        case .name: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .type: { $0.category.rawValue < $1.category.rawValue }
        case .date: { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .path: { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }
    }

    func startScan() {
        guard let volume = selectedVolume, !isScanning else { return }
        let previousCount: Int?
        if let previous = snapshot, previous.root.standardizedFileURL.path == volume.url.standardizedFileURL.path, previous.completedAt != nil {
            previousCount = previous.progress.filesScanned + previous.progress.directoriesScanned
        } else {
            previousCount = nil
        }
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        selectedIDs.removeAll()
        if explorerCategoryContext != nil { categoryFilter = nil }
        explorerCategoryContext = nil
        currentDirectory = sidebar == .explorer ? volume.url : nil
        if sidebar == .explorer {
            explorerItems = []
            explorerIssues = []
            explorerIsLoading = true
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
                    } else if sidebar == .explorer,
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
                        loadExplorerDirectory(currentDirectory ?? volume.url)
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
        guard id != selectedVolumeID, volumes.contains(where: { $0.id == id }) else { return }
        if isScanning { stopScan() }
        let generation = UUID()
        scanGeneration = generation
        selectedVolumeID = id
        selectedIDs.removeAll()
        currentDirectory = nil
        browseTask?.cancel()
        explorerItems = []
        explorerIssues = []
        encounteredApplicationURLs.removeAll()
        trashRequestGeneration = UUID()
        requestedTrashPreflights = []
        showingTrashConfirmation = false
        explorerCategoryContext = nil
        directoryIndexStore = nil
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
    }

    func refreshVolumes() {
        let refreshed = StorageService.mountedVolumes()
        volumes = refreshed
        if !refreshed.contains(where: { $0.id == selectedVolumeID }), let fallback = refreshed.first {
            selectVolume(id: fallback.id)
        }
    }

    func loadApplications() {
        guard !applicationsAreLoading else { return }
        applicationsAreLoading = true
        let visibleApplications = explorerItems.filter { $0.isDirectory && $0.fileExtension == "app" }.map(\.url)
        let additional = Array(encounteredApplicationURLs.union(visibleApplications))
        Task { [weak self] in
            guard let self else { return }
            let discovered = await applicationDiscovery.discover(additionalURLs: additional)
            if let volume = selectedVolume,
               let store = try? DirectoryIndexStore(volumeID: volume.id, root: volume.url),
               let summaries = try? await store.summaries(forPaths: discovered.map { $0.bundleURL.path }) {
                applications = discovered.map { application in
                    InstalledApplication(
                        bundleURL: application.bundleURL,
                        bundleIdentifier: application.bundleIdentifier,
                        displayName: application.displayName,
                        version: application.version,
                        allocatedBytesUpperBound: summaries[application.bundleURL.standardizedFileURL.path]?.allocatedSize ?? 0,
                        bundleIdentity: application.bundleIdentity,
                        protectionReason: application.protectionReason
                    )
                }
            } else {
                applications = discovered
            }
            applicationsAreLoading = false
        }
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
        guard !trashInventoryIsLoading else { return }
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
            trashInventoryIsLoading = false
        }
    }

    func emptyTrashPermanently() {
        guard emptyTrashConfirmation == "VIDER", let inventory = trashInventory else { return }
        emptyTrashStep = .running
        Task { [weak self] in
            guard let self else { return }
            let result = await trashService.emptyTrash(inventory, confirmation: emptyTrashConfirmation, volumes: volumes)
            emptyTrashResult = result
            emptyTrashStep = .result
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

    func startDuplicateAnalysis(minimumSize: Int64 = 10 * 1_048_576) {
        guard let volume = selectedVolume, !duplicateIsAnalyzing else { return }
        duplicateTask?.cancel()
        duplicateReport = nil
        duplicateError = nil
        duplicateSelectedIDs.removeAll()
        duplicateIsAnalyzing = true
        duplicateProgress = DuplicateAnalysisProgress()
        let service = DuplicateAnalysisService()
        duplicateTask = Task { [weak self] in
            guard let self else { return }
            for await event in service.events(root: volume.url, minimumSize: minimumSize) {
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
        if item.isDirectory {
            if sidebar == .explorer {
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
        loadExplorerDirectory(volume.url)
    }

    func loadExplorerDirectory(_ directory: URL, allowPackageTraversal: Bool = false) {
        guard let volume = selectedVolume else { return }
        browseTask?.cancel()
        explorerCategoryContext = nil
        selectedIDs.removeAll()
        explorerShowsSmallItems = false
        currentDirectory = directory.standardizedFileURL
        explorerItems = []
        explorerIssues = []
        explorerIsLoading = true
        do {
            let store = try DirectoryIndexStore(volumeID: volume.id, root: volume.url)
            directoryIndexStore = store
            let browser = DirectoryBrowserService(volumeID: volume.id, root: volume.url, indexStore: store)
            browseTask = Task { [weak self] in
                guard let self else { return }
                for await event in browser.browse(
                    directory: directory,
                    options: DirectoryBrowseOptions(includeHidden: true, batchSize: 256, allowPackageTraversal: allowPackageTraversal)
                ) {
                    guard !Task.isCancelled, selectedVolumeID == volume.id else { break }
                    switch event {
                    case .started:
                        explorerIsLoading = true
                    case .batch(_, let items):
                        explorerItems.append(contentsOf: items)
                        encounteredApplicationURLs.formUnion(
                            items.filter { $0.isDirectory && $0.fileExtension == "app" }.map(\.url)
                        )
                    case .issue(let issue):
                        if explorerIssues.count < 200 { explorerIssues.append(issue) }
                    case .completed:
                        explorerIsLoading = false
                    case .cancelled:
                        explorerIsLoading = false
                    }
                }
            }
        } catch {
            explorerIsLoading = false
            alertMessage = error.localizedDescription
        }
    }

    func requestTrashSelection() {
        requestTrash(items: selectedItems)
    }

    func requestTrash(items: [FileSystemItem]) {
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
        guard !preflights.isEmpty else { return }
        showingTrashConfirmation = false
        requestedTrashPreflights = []
        trashRequestGeneration = UUID()
        Task {
            let results = await trashService.trashWithResults(preflights)
            let trashedPaths = Set(results.filter { $0.status == .trashed }.map { $0.originalURL.standardizedFileURL.path })
            let succeeded = items.filter { trashedPaths.contains($0.url.standardizedFileURL.path) }
            if !succeeded.isEmpty {
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
            if !failures.isEmpty {
                alertMessage = "\(succeeded.count) élément(s) déplacé(s), \(failures.count) échec(s).\n" + failures.prefix(3).compactMap(\.errorDescription).joined(separator: "\n")
            }
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
