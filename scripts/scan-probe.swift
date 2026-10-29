import Foundation
import StorageCore

@main struct ScanProbe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let start = ContinuousClock.now
        var snapshot: ScanSnapshot?
        for await event in StorageScanner().scan(root: root, volumeID: ProcessInfo.processInfo.environment["STORAGESCOPE_BENCHMARK_VOLUME"] ?? "isolated-scan-comparison") {
            if case .completed(let value) = event { snapshot = value }
        }
        guard let snapshot else { throw CocoaError(.fileReadUnknown) }
        let duration = start.duration(to: .now)
        let result: [String: Any] = [
            "seconds": Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18,
            "files": snapshot.progress.filesScanned, "directories": snapshot.progress.directoriesScanned,
            "logicalBytes": snapshot.progress.logicalBytesDiscovered, "allocatedBytes": snapshot.progress.allocatedBytesDiscovered,
            "skipped": snapshot.progress.skippedItems, "permissionErrors": snapshot.progress.permissionErrors,
            "complete": snapshot.categoryReport.isComplete,
            "categories": Dictionary(uniqueKeysWithValues: snapshot.categoryReport.summaries.map {
                ($0.category.rawValue, ["files": Int64($0.fileCount), "logical": $0.logicalBytes, "allocated": $0.allocatedBytes])
            })
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
