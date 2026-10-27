import AppKit
import Foundation
import StorageCore

/// Real overview -> category transitions with long names, selection, scrolling
/// and repeated window resizes. No existing user file is opened or deleted.
@MainActor
enum CategoryLayoutValidation {
    static func run(model: AppModel, window: NSWindow, destination: URL) async throws {
        let baseline = ProcessInfo.processInfo.environment["STORAGESCOPE_LAYOUT_BASELINE"] == "1"
        let previous = model.snapshot
        defer { model.snapshot = previous; model.sidebar = .applications }
        let categories: [ItemCategory] = [.document, .applicationData, .image, .video]
        var summaries: [CategorySummary] = []
        let longName = String(repeating: "nom très long 動画 📁 ", count: 10)
        for category in categories {
            var files: [FileSystemItem] = []
            for index in 0..<650 {
                let prefix = "/Volumes/StorageScope-Layout-Fixture/" + category.rawValue + "/" + String(index) + "-"
                let url = URL(fileURLWithPath: prefix + longName + ".dat")
                let bytes = Int64(650 - index) * 4096
                files.append(FileSystemItem(url: url, logicalSize: bytes, allocatedSize: bytes,
                    isDirectory: false, category: category, safety: .personal, sizeIsKnown: true))
            }
            summaries.append(CategorySummary(category: category, logicalBytes: 8_000_000_000,
                allocatedBytes: 8_000_000_000, fileCount: 100_000, topContributors: files))
        }
        let report = CategoryReport(summaries: summaries, isComplete: false)
        model.snapshot = ScanSnapshot(root: model.selectedVolume?.url ?? URL(fileURLWithPath: "/"),
            progress: ScanProgress(), topFiles: [], topDirectories: [], directoryContents: [:], issues: [],
            completedAt: nil, volumeID: model.selectedVolumeID, categoryReport: report)
        let deadline = Date().addingTimeInterval(65)
        var transitions = 0
        while Date() < deadline {
            let category = categories[transitions % categories.count]
            model.sidebar = .overview
            try await Task.sleep(for: .milliseconds(70))
            model.searchText = "ancien filtre sans résultat"
            model.openCategory(category) // The exact action invoked by the overview tile.
            try await Task.sleep(for: .milliseconds(100))
            window.setContentSize(NSSize(width: [740.0, 949, 951, 1120][transitions % 4], height: transitions % 2 == 0 ? 560 : 800))
            try await Task.sleep(for: .milliseconds(80))
            if !baseline {
                let readyDeadline = Date().addingTimeInterval(2)
                while Date() < readyDeadline && (findTable(window.contentView)?.numberOfRows != 500 || model.explorerVisibleItems.count != 500) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard model.sidebar == .explorer, model.explorerCategoryContext?.category == category,
                      model.explorerItems.count == 500, model.explorerVisibleItems.count == 500,
                      model.explorerCategoryContext?.totalFileCount == 100_000,
                      let table = findTable(window.contentView), !table.usesAutomaticRowHeights,
                      NSStringFromClass(type(of: table)).hasSuffix("FileRowsTable"), table.numberOfRows == 500 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(40))
                guard model.selectedIDs == [model.explorerVisibleItems[0].id] else { throw CocoaError(.fileReadCorruptFile) }
                table.scrollRowToVisible(499); table.scrollRowToVisible(0)
            }
            transitions += 1
        }
        let result: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "categoryTransitions": transitions, "durationSeconds": 65, "longNames": true,
            "rowsPerCategory": model.explorerItems.count, "fixedHeightNativeCells": !baseline,
            "selectionAndScrollingVerified": !baseline]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: destination.appendingPathComponent("macos-category-layout-validation.json"))
        print("PASS overview/category layout stress: \(transitions) transitions over 65 seconds")
    }
    private static func findTable(_ view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = findTable(child) { return table } }
        return nil
    }
}
