import Foundation
import StorageCore

func testLinkedEntriesPreserveSiblingCoverage() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".StorageScope-Link-Coverage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-loop"), withDestinationURL: root)
    var expectedBytes: Int64 = 0
    for folderIndex in 0..<20 {
        let folder = root.appendingPathComponent("sibling-\(folderIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for fileIndex in 0..<5 {
            let file = folder.appendingPathComponent("file-\(fileIndex).txt")
            try Data([1]).write(to: file)
            expectedBytes += Int64(try file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize ?? 0)
        }
    }
    var result: ScanSnapshot?
    for await event in StorageScanner().scan(root: root) { if case .completed(let snapshot) = event { result = snapshot } }
    try expect(result?.progress.filesScanned == 100 && result?.progress.logicalBytesDiscovered == 100,
        "Ignoring a link must not skip a sibling directory or traverse its target")
    try expect(result?.progress.skippedItems == 1, "The link itself must remain excluded")
    let size = InstallationSizeService.measure(root)
    try expect(size.state == .partial && size.bytes == expectedBytes, "Application measurement must keep every sibling file while excluding the link")
}
