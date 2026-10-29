import Foundation
import StorageCore

@main struct ScanProbe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let start = ContinuousClock.now
        #if STORAGESCOPE_TREE_PROBE
        if CommandLine.arguments.contains("--replay") {
            let volumeID = ProcessInfo.processInfo.environment["STORAGESCOPE_BENCHMARK_VOLUME"] ?? "isolated-scan-comparison"
            trace("replay-start")
            let expectedLogical = ProcessInfo.processInfo.environment["STORAGESCOPE_PROBE_EXPECTED_LOGICAL"].flatMap(Int64.init)
            for await event in PersistentScanSynchronizer.synchronize(root: root, volumeID: volumeID) {
                switch event {
                case let .updated(state, settled: true):
                    trace("replay-settled")
                    if expectedLogical == nil || state.snapshot.categoryReport.identifiedLogicalBytes == expectedLogical {
                        try emit(state.snapshot, duration: start.duration(to: .now))
                        // The application keeps watching; this one-shot benchmark
                        // process deliberately ends after its committed measurement.
                        exit(EXIT_SUCCESS)
                    }
                case let .status(.requiresScan, reason): throw NSError(domain: "ScanProbe.Journal", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
                case let .status(status, _): trace("replay-status:" + status.rawValue)
                case .updated(_, settled: false): trace("replay-restored")
                }
            }
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        var snapshot: ScanSnapshot?
        for await event in StorageScanner().scan(root: root, volumeID: ProcessInfo.processInfo.environment["STORAGESCOPE_BENCHMARK_VOLUME"] ?? "isolated-scan-comparison") {
            if case .completed(let value) = event { snapshot = value }
        }
        guard let snapshot else { throw CocoaError(.fileReadUnknown) }
        try emit(snapshot, duration: start.duration(to: .now))
    }
    static func trace(_ value: String) { try? FileHandle.standardError.write(contentsOf: Data((value + "\n").utf8)) }
    static func emit(_ snapshot: ScanSnapshot, duration: Duration) throws {
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
        var data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
