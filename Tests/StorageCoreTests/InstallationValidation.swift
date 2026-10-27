import Foundation
import StorageCore

private actor SizeBatches {
    var results: [String: InstallationSize] = [:]
    func append(_ batch: [String: InstallationSize]) { results.merge(batch) { _, new in new } }
}

func testInstallationSizes() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".StorageScopeSizeFixture-\(UUID().uuidString)")
    let app = root.appendingPathComponent("Fixture.app"), manager = FileManager.default
    try manager.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let payload = app.appendingPathComponent("payload")
    try Data(repeating: 97, count: 131_072).write(to: payload)
    try manager.linkItem(at: payload, to: app.appendingPathComponent("hard-link"))
    let measured = InstallationSizeService.measure(app)
    let physical = try payload.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize!
    try expect(measured.state == .measured && measured.bytes == Int64(physical), "Mesurer indépendamment du scan et compter les liens physiques une seule fois")
    let outside = root.appendingPathComponent("external")
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 400_000).write(to: outside.appendingPathComponent("secret"))
    try manager.createSymbolicLink(at: app.appendingPathComponent("link"), withDestinationURL: outside)
    let partial = InstallationSizeService.measure(app)
    try expect(partial.state == .partial && partial.bytes == measured.bytes, "Ne pas suivre de lien ; afficher une mesure partielle")
    try expect(InstallationSizeService.measure(root.appendingPathComponent("missing")).bytes == nil, "Une installation absente ne vaut pas zéro")
    let empty = root.appendingPathComponent("empty"); try manager.createDirectory(at: empty, withIntermediateDirectories: true)
    try expect(InstallationSizeService.measure(empty) == InstallationSize(bytes: 0, state: .measured), "Un dossier réellement vide est mesuré à zéro")
    let collector = SizeBatches()
    await InstallationSizeService.measureAll([app, app, empty]) { await collector.append($0) }
    let results = await collector.results
    try expect(results.count == 2, "Mutualiser les chemins communs aux jeux et applications")
    let task = Task { await InstallationSizeService.measureAll([app]) { await collector.append($0) } }
    task.cancel(); await task.value
}

func testLocalDiagnostics() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".StorageScopeDiagnosticsFixture-\(UUID().uuidString)")
    let diagnostics = LocalDiagnostics(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    try expect(!diagnostics.begin(version: "3.5.0"), "Le premier lancement n’est pas un crash")
    for _ in 0..<1100 { diagnostics.record(action: "test de rotation", detail: String(repeating: "x", count: 12_000)) }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    try expect(files.filter { $0.lastPathComponent.hasPrefix("StorageScope-crashes.log") }.count <= 6, "Limiter le journal courant et cinq sauvegardes")
    let output = root.appendingPathComponent("export.log"); try diagnostics.export(to: output)
    let text = try String(contentsOf: output, encoding: .utf8)
    try expect(text.contains("v3.5.0"), "Exporter des diagnostics versionnés sans réseau")
    diagnostics.finish()
    try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("session.json").path), "Retirer le marqueur après un arrêt normal")
    try JSONSerialization.data(withJSONObject: ["pid": Int32.max, "session": "interrupted"]).write(to: root.appendingPathComponent("session.json"))
    try expect(diagnostics.begin(version: "3.5.0"), "Détecter une session dont le processus a disparu")
    diagnostics.finish()
}
