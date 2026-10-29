import AppKit
import StorageCore
import SwiftUI

struct FolderBubblesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var explorerState: ExplorerPresentation
    var body: some View {
        let _ = explorerState.currentDirectory
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Text(model.bubbleMessage).font(.callout).foregroundStyle(.secondary)
                if model.isScanning {
                    HStack { ProgressView().controlSize(.small); Text("Analyse du disque en cours — tailles partielles"); Button("Annuler") { model.cancelExplorerLoading() } }
                }
                HStack {
                    Text("\(model.explorerVisibleItems.count) éléments affichés").font(.caption)
                    Spacer()
                    Button("Dossier parent", systemImage: "arrow.up") { goUp() }
                }
                if proxy.size.width >= 720 {
                    HSplitView {
                        ExplorerListTable(items: model.explorerVisibleItems).disabled(model.explorerPendingDirectory != nil).frame(minWidth: 270, idealWidth: 320)
                        FolderBubbleDiagram().frame(minWidth: 280)
                    }
                } else {
                    VSplitView {
                        FolderBubbleDiagram().frame(minHeight: 160)
                        ExplorerListTable(items: model.explorerVisibleItems).disabled(model.explorerPendingDirectory != nil).frame(minHeight: 130)
                    }
                }
                Text("Surfaces proportionnelles · Les espaces entre bulles ne représentent pas l’espace libre.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }.onAppear { model.ensureBubbleAnalysis() }
    }
    private func goUp() {
        guard let current = model.currentDirectory, let root = model.selectedVolume?.url,
              current.standardizedFileURL.path != root.standardizedFileURL.path else { return }
        model.navigationBack = true; model.navigationAnchor = .center
        model.loadExplorerDirectory((model.explorerPendingDirectory ?? current).deletingLastPathComponent())
    }
}

enum BubbleGeometry {
    static func rect(_ node: FolderBubble, size: CGSize) -> CGRect {
        let diameter = max(0, min(size.width, size.height) - 12)
        let radius = CGFloat(node.circle.radius) * diameter / 2
        return CGRect(x: size.width / 2 + CGFloat(node.circle.x) * diameter / 2 - radius,
                      y: size.height / 2 + CGFloat(node.circle.y) * diameter / 2 - radius,
                      width: radius * 2, height: radius * 2)
    }
}

private struct FolderBubbleDiagram: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var explorerState: ExplorerPresentation
    private var nodes: [FolderBubble] { model.bubbleFrame?.folders ?? [] }
    var body: some View {
        let _ = explorerState.currentDirectory
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                FolderBubbleDrawing(nodes: nodes).allowsHitTesting(false)
                NativeBubbleControls(model: model, nodes: nodes, enabled: model.explorerPendingDirectory == nil)
                if nodes.isEmpty && !model.bubbleIsLoading && !model.explorerIsLoading && !model.isScanning {
                    ContentUnavailableView("Aucun élément mesuré", systemImage: "folder", description: Text(model.explorerIssues.first?.message ?? "Les tailles inconnues restent disponibles dans la liste."))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                if model.explorerLoaderVisible || (model.bubbleIsLoading && model.bubbleFrame == nil) || model.isScanning && model.bubbleFrame?.totalBytes == nil {
                    BriocheLoadingView(message: model.explorerIsLoading ? "Lecture du dossier…" : model.isScanning ? "Analyse du disque…" : "Préparation du graphique…", cancel: model.cancelExplorerLoading)
                        .frame(width: min(260, proxy.size.width), height: 160).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).position(x: max(130, proxy.size.width - 135), y: 85)
                }
            }
            .onAppear { model.resizeBubbleLayout(width: proxy.size.width, height: proxy.size.height) }
            .onChange(of: proxy.size) { _, size in model.resizeBubbleLayout(width: size.width, height: size.height) }
        }
        .softTransition(model.navigationRevision.uuidString, duration: MotionTokens.navigation, back: model.navigationBack, anchor: model.navigationAnchor)
    }
}

private struct FolderBubbleDrawing: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var explorerState: ExplorerPresentation
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let nodes: [FolderBubble]
    var body: some View {
        let _ = explorerState.currentDirectory
        Canvas { context, size in
            for node in nodes {
                let rect = BubbleGeometry.rect(node, size: size)
                let path = Path(ellipseIn: rect.insetBy(dx: 1, dy: 1))
                let color: Color = node.isAggregate ? .gray : node.isDirectory ? AppTheme.accent : .indigo
                context.fill(path, with: .linearGradient(Gradient(colors: [color, color.opacity(0.85)]), startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                let matched = model.explorerHoveredID == node.path || model.selectedIDs.contains(node.path) || !model.searchText.isEmpty && node.name.localizedCaseInsensitiveContains(model.searchText)
                context.stroke(path, with: .color(Color.primary.opacity(differentiateWithoutColor || matched ? 1 : 0.4)), lineWidth: matched ? 3 : 1)
                if rect.width >= 70 {
                    let text = Text(node.name + "\n" + ByteCountFormatter.storage.string(fromByteCount: node.bytes)).font(.system(size: min(14, max(12, rect.width / 10)))).foregroundColor(.white)
                    context.draw(context.resolve(text), in: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.30))
                }
            }
        }.accessibilityHidden(true)
    }
}
