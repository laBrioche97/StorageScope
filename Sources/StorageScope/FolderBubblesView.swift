import AppKit
import StorageCore
import SwiftUI

struct FolderBubblesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.bubbleMessage).font(.callout).foregroundStyle(.secondary)
            if model.isScanning {
                ScanProgressView(status: model.scanStatus)
                Button("Annuler l’analyse") { model.stopScan(); model.ensureBubbleAnalysis() }
            }
            folderHeader
            FolderBubbleDiagram()
            Button(directFileLabel) { model.showDirectFiles() }
            Text("Les surfaces comparent les dossiers frères. Les espaces entre bulles ne représentent pas l’espace libre.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
        .onAppear { model.ensureBubbleAnalysis() }
    }
    private var folderHeader: some View {
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
    }
    private var directFileLabel: String {
        let size = model.bubbleFrame?.directFileBytes.map { " · " + ByteCountFormatter.storage.string(fromByteCount: $0) } ?? ""
        return "Fichiers dans ce dossier" + size + " — Voir la liste"
    }
}

private enum BubbleGeometry {
    static func rect(_ node: FolderBubble, size: CGSize) -> CGRect {
        let diameter = max(0, min(size.width, size.height) - 8)
        let radius = CGFloat(node.circle.radius) * diameter / 2
        return CGRect(x: size.width / 2 + CGFloat(node.circle.x) * diameter / 2 - radius,
                      y: size.height / 2 + CGFloat(node.circle.y) * diameter / 2 - radius,
                      width: radius * 2, height: radius * 2)
    }
}

private struct FolderBubbleDiagram: View {
    @EnvironmentObject private var model: AppModel
    private var nodes: [FolderBubble] { (model.bubbleFrame?.folders ?? []).sorted { $0.depth < $1.depth } }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                FolderBubbleDrawing(nodes: nodes)
                ForEach(nodes) { node in
                    FolderBubbleControl(node: node, bounds: BubbleGeometry.rect(node, size: proxy.size))
                }
                if nodes.isEmpty { emptyState.frame(width: proxy.size.width, height: proxy.size.height) }
            }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder").font(.largeTitle)
            Text(model.isScanning ? "Calcul des tailles en cours…" : "Aucun sous-dossier mesuré")
            Button("Voir les fichiers dans la Liste") { model.showDirectFiles() }
        }
    }
}

private struct FolderBubbleDrawing: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let nodes: [FolderBubble]
    var body: some View {
        Canvas { context, size in draw(context, size: size) }.accessibilityHidden(true)
    }
    private func draw(_ context: GraphicsContext, size: CGSize) {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let colors: [Color] = [.purple, .blue, .teal]
        for node in nodes {
            let rect = BubbleGeometry.rect(node, size: size)
            let path = Path(ellipseIn: rect.insetBy(dx: 1, dy: 1))
            let color: Color = node.isAggregate ? .gray : colors[node.depth % colors.count]
            context.fill(path, with: .color(color.opacity(0.75)))
            let matched = !query.isEmpty && node.name.localizedCaseInsensitiveContains(query)
            let stroke = Color.primary.opacity(differentiateWithoutColor || matched ? 1 : 0.5)
            context.stroke(path, with: .color(stroke), lineWidth: matched ? 3 : 1)
            if rect.width > 70 { drawLabel(node, context: context, rect: rect) }
        }
    }
    private func drawLabel(_ node: FolderBubble, context: GraphicsContext, rect: CGRect) {
        let hasChildren = nodes.contains { $0.depth == node.depth + 1 && $0.path.hasPrefix(node.path + "/") }
        let text = hasChildren ? node.name : node.name + "\n" + ByteCountFormatter.storage.string(fromByteCount: node.bytes)
        let label = Text(text).font(.system(size: min(13, rect.width / 10))).foregroundColor(.white)
        let labelRect: CGRect
        if hasChildren {
            labelRect = CGRect(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.06, width: rect.width * 0.7, height: rect.height * 0.18)
        } else { labelRect = rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.33) }
        context.draw(context.resolve(label), in: labelRect)
        if hasChildren {
            let bytes = Text(ByteCountFormatter.storage.string(fromByteCount: node.bytes)).font(.system(size: min(12, rect.width / 12))).foregroundColor(.white)
            context.draw(bytes, at: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.1))
        }
    }
}

private struct FolderBubbleControl: View {
    @EnvironmentObject private var model: AppModel
    let node: FolderBubble
    let bounds: CGRect
    var body: some View {
        Button { model.openBubble(node) } label: { Circle().fill(Color.clear).contentShape(Circle()) }
            .buttonStyle(.plain)
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
            .accessibilityLabel(node.name)
            .accessibilityValue(ByteCountFormatter.storage.string(fromByteCount: node.bytes))
            .help(annotation)
            .contextMenu { contextActions }
    }
    @ViewBuilder private var contextActions: some View {
        if !node.isAggregate {
            Button("Ouvrir le dossier") { model.openBubble(node) }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }
            Button("Mettre à la corbeille…", role: .destructive, action: requestTrash).disabled(model.operationsAreBusy)
            Button("Copier le chemin") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.path, forType: .string) }
        }
    }
    private func requestTrash() {
        let item = FileSystemItem(url: URL(fileURLWithPath: node.path), logicalSize: node.bytes, allocatedSize: node.bytes, isDirectory: true)
        model.requestTrash(items: [item])
    }
    private var annotation: String {
        var text = node.name + "\n" + node.path + "\n" + ByteCountFormatter.storage.string(fromByteCount: node.bytes)
        let total = node.parentBytes > 0 ? node.parentBytes : model.bubbleFrame?.totalBytes ?? 0
        if total > 0 { text += String(format: " · %.1f %% du dossier parent", Double(node.bytes) * 100 / Double(total)) }
        return text
    }
}
