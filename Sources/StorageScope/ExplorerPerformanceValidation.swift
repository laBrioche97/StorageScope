import AppKit
import Foundation
import StorageCore

@MainActor enum ExplorerPerformanceValidation {
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
        let store = try DirectoryIndexStore(volumeID: volume.id, root: root)
        try await store.replaceAll([root, first, second].map { DirectorySummary(volumeID: volume.id, url: $0, logicalSize: 1000, allocatedSize: 4_096_000) }, scanID: UUID(), indexVersion: DirectoryIndexStore.schemaVersion)
        model.volumes = [volume]; model.selectedVolumeID = volume.id
        model.currentDirectory = first; model.snapshot = ScanSnapshot(root: root, progress: ScanProgress(), topFiles: [], topDirectories: [], directoryContents: [:], issues: [], completedAt: Date(), volumeID: volume.id)
        model.sidebar = .explorer; model.resetSectionFilters(); model.explorerDisplayMode = .bubbles
        window.setContentSize(NSSize(width: 1120, height: 800))
        for folder in [first, second] {
            model.loadExplorerDirectory(folder)
            let deadline = Date().addingTimeInterval(12)
            while model.explorerIsLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            guard model.currentDirectory == folder, model.explorerItems.count == 1000, !model.explorerIsLoading else { throw CocoaError(.fileReadUnknown) }
        }
        var publication: [Double] = [], rendered: [Double] = []
        for index in 0..<24 {
            let folder = index % 2 == 0 ? first : second
            let start = ContinuousClock.now
            model.loadExplorerDirectory(folder)
            let deadline = Date().addingTimeInterval(2)
            while model.currentDirectory != folder && Date() < deadline { await Task.yield() }
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
            "preferredModePreserved": true, "frameRateTarget": 60, "frameRateMeasured": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("macos-navigation-performance.json"))
        guard p95(publication) < 50, p95(rendered) < 100 else {
            throw NSError(domain: "StorageScope.Performance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cached navigation exceeded its publication/feedback budget: \(result)"])
        }
        try Data([2]).write(to: second.appendingPathComponent("B-new-file.bin"))
        model.loadExplorerDirectory(second)
        let deadline = Date().addingTimeInterval(12)
        while model.explorerIsLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard model.explorerItems.count == 1001 else { throw CocoaError(.fileReadUnknown) }
        print("PASS 1000-item cached navigation, actual native rows and external-change revalidation")
    }
    private static func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    private static func findFileTable(_ view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, NSStringFromClass(type(of: table)).hasSuffix("FileRowsTable") { return table }
        return view.subviews.lazy.compactMap { findFileTable($0) }.first
    }
}
