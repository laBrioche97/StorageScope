import Foundation
import StorageCore

func testFolderBubbles() async throws {
    let weights: [Double] = [16, 9, 4, 1]
    let circles = CirclePacking.pack(weights)
    try expect(circles == CirclePacking.pack(weights), "Le placement doit être déterministe")
    for (index, circle) in circles.enumerated() {
        try expect(circle.x.isFinite && hypot(circle.x, circle.y) + circle.radius <= 1.000001, "Cercle hors de son contenant")
        try expect(abs(pow(circle.radius / circles[0].radius, 2) - weights[index] / weights[0]) < 0.000001, "Les surfaces doivent suivre les tailles")
        for other in circles.prefix(index) {
            try expect(hypot(circle.x - other.x, circle.y - other.y) >= circle.radius + other.radius - 0.000001, "Chevauchement entre dossiers frères")
        }
    }
    try expect(CirclePacking.pack([]).isEmpty && CirclePacking.pack([0, 0]).isEmpty, "Poids nuls")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeBubbles-\(UUID())")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let store = try DirectoryIndexStore(volumeID: "bubbles", root: fixture, databaseURL: fixture.appendingPathComponent("index.sqlite"))
    var summaries: [DirectorySummary] = []
    summaries.append(DirectorySummary(volumeID: "bubbles", url: fixture, logicalSize: 500_000, allocatedSize: 500_000))
    for index in 0..<100 {
        let parent = fixture.appendingPathComponent(String(format: "folder-%03d", index))
        summaries.append(DirectorySummary(volumeID: "bubbles", url: parent, logicalSize: 1000, allocatedSize: 1000))
        for child in 0..<40 {
            summaries.append(DirectorySummary(volumeID: "bubbles", url: parent.appendingPathComponent("child-\(child)"), logicalSize: 20, allocatedSize: 20))
        }
    }
    try await store.replaceAll(summaries)
    let frame = try await store.bubbleFrame(forPath: fixture.path, partial: true)
    try expect(frame.folders.count <= 200 && frame.folders.allSatisfy { $0.depth < 3 }, "Le graphique doit rester borné")
    let siblings = frame.folders.filter { $0.depth == 0 }
    try expect(siblings.count == 32 && siblings.reduce(0) { $0 + $1.bytes } == 100_000, "Regroupement sans perte d’octets")
    try expect(siblings.last?.isAggregate == true && frame.directFileBytes == 400_000 && frame.isPartial, "Autres dossiers et fichiers directs")
    let unknown = try await store.bubbleFrame(forPath: fixture.appendingPathComponent("unknown").path, partial: false)
    try expect(unknown.totalBytes == nil, "Une taille inconnue ne doit pas devenir zéro")

    let first = TrashInventory(items: [], issues: [])
    let different = TrashInventory(items: [], issues: [])
    let rejected = await TrashService().emptyTrash(first, authorization: .confirm(different), volumes: [])
    try expect(!rejected.confirmationAccepted, "Une confirmation ne doit pas autoriser un autre inventaire")
}
