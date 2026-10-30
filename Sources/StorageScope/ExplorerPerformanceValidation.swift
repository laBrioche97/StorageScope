import AppKit
import Foundation
import StorageCore

@MainActor enum ExplorerPerformanceValidation {
    static var measuring = false
    static var started = ContinuousClock.now
    static var stages: [[String: Any]] = []
    static func note(_ stage: String) {
        guard measuring, stages.count < 1000 else { return }
        stages.append(["stage": stage, "milliseconds": milliseconds(started.duration(to: .now))])
    }
    static func run(model: AppModel, window: NSWindow, destination: URL) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".StorageScope-Navigation-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("A", isDirectory: true), second = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [first, second] {
            for index in 0..<1000 { try Data([1]).write(to: folder.appendingPathComponent("\(folder.lastPathComponent)-\(index).bin")) }
        }
        let volume = StorageVolume(id: root.lastPathComponent, url: root, name: "Navigation fixture", capacity: 1_000_000_000, available: 500_000_000, isLocal: true, isInternal: true)
        let previousVolumes = model.volumes, previousID = model.selectedVolumeID, previousSnapshot = model.snapshot
        defer { model.volumes = previousVolumes; model.selectedVolumeID = previousID; model.snapshot = previousSnapshot; model.sidebar = .applications }
        var complete = false
        var scanDescription = "Aucun résultat complet reçu"
        for await event in StorageScanner().scan(root: root, volumeID: volume.id) {
            if case .completed(let result) = event {
                complete = result.progress.filesScanned == 2000 && result.indexVersion == DirectoryIndexStore.schemaVersion
                scanDescription = "fichiers=\(result.progress.filesScanned), versionIndex=\(result.indexVersion), erreurs=\(result.issues.prefix(3).map(\.message).joined(separator: "; "))"
            }
        }
        guard complete else { throw validationFailure("Analyse du jeu de référence : " + scanDescription) }
        model.volumes = [volume]; model.selectedVolumeID = volume.id
        model.snapshot = nil; model.currentDirectory = first
        await model.restoreLastScan()
        guard model.snapshot?.progress.filesScanned == 2000 else { throw CocoaError(.fileReadCorruptFile) }
        model.sidebar = .explorer; model.resetSectionFilters(); model.explorerDisplayMode = .bubbles
        window.setContentSize(NSSize(width: 1120, height: 800))
        for folder in [first, second] {
            model.loadExplorerDirectory(folder)
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline && (model.explorerIsLoading || model.currentDirectory != folder || model.explorerItems.count != 1000) { try await Task.sleep(for: .milliseconds(5)) }
            guard model.currentDirectory == folder, model.explorerItems.count == 1000, !model.explorerIsLoading else {
                throw validationFailure("Lecture initiale : attendu=\(folder.path), affiché=\(model.currentDirectory?.path ?? "aucun"), éléments=\(model.explorerItems.count), lecture=\(model.explorerIsLoading), erreurs=\(model.explorerIssues.prefix(3).map(\.message).joined(separator: "; "))")
            }
        }
        var publication: [Double] = [], rendered: [Double] = []
        let profiling = ProcessInfo.processInfo.environment["STORAGESCOPE_PROFILE_EXPLORER"] == "1"
        if profiling {
            try Data().write(to: destination.appendingPathComponent("profile-ready"))
            try await Task.sleep(for: .seconds(3))
        }
        measuring = true
        defer { measuring = false }
        for index in 0..<(profiling ? 120 : 24) {
            let folder = index % 2 == 0 ? first : second
            let start = ContinuousClock.now
            started = start
            model.loadExplorerDirectory(folder)
            let deadline = Date().addingTimeInterval(2)
            while model.currentDirectory != folder && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            publication.append(milliseconds(start.duration(to: .now)))
            while Date() < deadline {
                if let table = findFileTable(window.contentView), table.numberOfRows == 1000,
                   let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView,
                   cell.textField?.stringValue.hasPrefix(folder.lastPathComponent + "-") == true { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            rendered.append(milliseconds(start.duration(to: .now)))
            guard model.currentDirectory == folder, model.explorerItems.count == 1000, model.explorerDisplayMode == .bubbles else { throw CocoaError(.fileReadUnknown) }
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)] }
        let result: [String: Any] = ["version": AppIdentity.version, "itemsPerFolder": 1000, "navigations": publication.count,
            "cachedPublicationP95Milliseconds": p95(publication), "nativeRowsP95Milliseconds": p95(rendered),
            "preferredModePreserved": true, "frameRateTarget": 60, "frameRateMeasured": false, "stages": stages]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("macos-navigation-performance.json"))
        guard p95(publication) < 50, p95(rendered) < 100 else {
            throw NSError(domain: "StorageScope.Performance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cached navigation exceeded its publication/feedback budget: \(result)"])
        }
        if !profiling { try await ExplorerInteractionValidation.run(model: model, window: window, root: root, first: first, destination: destination) }
        try Data([2]).write(to: second.appendingPathComponent("B-new-file.bin"))
        model.loadExplorerDirectory(second)
        let deadline = Date().addingTimeInterval(12)
        // Cached publication is deliberately immediate. Wait for the observable
        // background revalidation result, not its loading indicator, which can
        // already be false while cached contents are displayed.
        while Date() < deadline && (model.explorerIsLoading || model.currentDirectory != second || model.explorerItems.count != 1001) { try await Task.sleep(for: .milliseconds(5)) }
        guard model.currentDirectory == second, model.explorerItems.count == 1001 else {
            throw validationFailure("Actualisation du cache : attendu=1001, éléments=\(model.explorerItems.count), affiché=\(model.currentDirectory?.path ?? "aucun")")
        }
        let originalScanID = model.snapshot?.scanID
        let originalCompletedAt = model.snapshot?.completedAt
        let fresh = root.appendingPathComponent("just-created", isDirectory: true)
        let unmeasured = fresh.appendingPathComponent("unmeasured-child", isDirectory: true)
        try FileManager.default.createDirectory(at: unmeasured, withIntermediateDirectories: true)
        try Data([2]).write(to: unmeasured.appendingPathComponent("new.bin"))
        model.loadExplorerDirectory(fresh)
        let freshDeadline = Date().addingTimeInterval(12)
        while Date() < freshDeadline && (model.explorerIsLoading || model.currentDirectory != fresh) { try await Task.sleep(for: .milliseconds(5)) }
        guard !model.isScanning, model.snapshot?.scanID == originalScanID,
              model.snapshot?.completedAt == originalCompletedAt else {
            throw validationFailure("Un dossier sans taille ne doit pas relancer l’analyse complète enregistrée.")
        }
        print("PASS 1000-item cached navigation, actual native rows and external-change revalidation")
    }
    private static func validationFailure(_ message: String) -> NSError {
        NSError(domain: "StorageScope.NavigationValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    private static func findFileTable(_ view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, NSStringFromClass(type(of: table)).hasSuffix("FileRowsTable") { return table }
        return view.subviews.lazy.compactMap { findFileTable($0) }.first
    }
}
