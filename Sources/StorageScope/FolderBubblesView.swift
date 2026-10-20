import AppKit
import StorageCore
import SwiftUI

struct FolderBubblesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.bubbleMessage).font(.callout).foregroundStyle(.secondary)
            if model.isScanning {
                ScanProgressView(status: model.scanStatus)
                Button("Annuler l’analyse") { model.stopScan(); model.ensureBubbleAnalysis() }
            }
            HStack {
                if let total = model.bubbleFrame?.totalBytes {
                    Text(ByteCountFormatter.storage.string(fromByteCount: total)).font(.headline).monospacedDigit()
                }
                if let date = model.bubbleFrame?.updatedAt { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Dossier parent", systemImage: "arrow.up") {
                    guard let current = model.currentDirectory, let root = model.selectedVolume?.url,
                          current.standardizedFileURL.path != root.standardizedFileURL.path else { return }
                    model.loadExplorerDirectory(current.deletingLastPathComponent())
                }
            }
            GeometryReader { proxy in
                let diameter = max(0, min(proxy.size.width, proxy.size.height) - 8)
                let nodes = model.bubbleFrame?.folders ?? []
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for node in nodes.sorted(by: { $0.depth < $1.depth }) {
                            let rect = rect(node, size: size, diameter: diameter)
                            let path = Path(ellipseIn: rect.insetBy(dx: 1, dy: 1))
                            let color: Color = node.isAggregate ? .gray : [.purple, .blue, .teal][node.depth % 3]
                            context.fill(path, with: .color(color.opacity(0.75)))
                            let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let matched = !query.isEmpty && node.name.localizedCaseInsensitiveContains(query)
                            context.stroke(path, with: .color(.primary.opacity(differentiateWithoutColor || matched ? 1 : 0.5)), lineWidth: matched ? 3 : 1)
                            if rect.width > 70 {
                                let label = Text(node.name + "\n" + ByteCountFormatter.storage.string(fromByteCount: node.bytes))
                                    .font(.system(size: min(13, rect.width / 10))).foregroundColor(.white)
                                context.draw(label, in: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.33))
                            }
                        }
                    }.accessibilityHidden(true)
                    ForEach(nodes.sorted(by: { $0.depth < $1.depth })) { node in
                        let frame = rect(node, size: proxy.size, diameter: diameter)
                        Button { model.openBubble(node) } label: {
                            Circle().fill(.clear).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityLabel(node.name)
                        .accessibilityValue(ByteCountFormatter.storage.string(fromByteCount: node.bytes))
                        .help(node.name + "\n" + node.path + "\n" + ByteCountFormatter.storage.string(fromByteCount: node.bytes) + percentage(node))
                        .contextMenu {
                            if !node.isAggregate {
                                Button("Ouvrir le dossier") { model.openBubble(node) }
                                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }
                                Button("Copier le chemin") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.path, forType: .string) }
                            }
                        }
                    }
                    if nodes.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder").font(.largeTitle)
                            Text(model.isScanning ? "Calcul des tailles en cours…" : "Aucun sous-dossier mesuré")
                            Button("Voir les fichiers dans la Liste") { model.showDirectFiles() }
                        }.frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
            Button(directFileLabel) { model.showDirectFiles() }
            Text("Les surfaces comparent les dossiers frères. Les espaces entre bulles ne représentent pas l’espace libre.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
        .onAppear { model.ensureBubbleAnalysis() }
    }

    private var directFileLabel: String {
        let size = model.bubbleFrame?.directFileBytes.map { " · " + ByteCountFormatter.storage.string(fromByteCount: $0) } ?? ""
        return "Fichiers dans ce dossier" + size + " — Voir la liste"
    }
    private func percentage(_ node: FolderBubble) -> String {
        guard let total = node.parentBytes > 0 ? node.parentBytes : model.bubbleFrame?.totalBytes, total > 0 else { return "" }
        return String(format: " · %.1f %% du dossier parent", Double(node.bytes) * 100 / Double(total))
    }
    private func rect(_ node: FolderBubble, size: CGSize, diameter: Double) -> CGRect {
        CGRect(x: size.width / 2 + node.circle.x * diameter / 2 - node.circle.radius * diameter / 2,
               y: size.height / 2 + node.circle.y * diameter / 2 - node.circle.radius * diameter / 2,
               width: node.circle.radius * diameter, height: node.circle.radius * diameter)
    }
}
