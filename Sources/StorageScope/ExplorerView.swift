import AppKit
import StorageCore
import SwiftUI

struct StorageExplorerView: View {
    @EnvironmentObject private var model: AppModel

    private var totalBytes: Int64 {
        max(1, model.explorerVisibleItems.reduce(0) { $0 + $1.allocatedSize })
    }

    private var splitItems: (visible: [FileSystemItem], small: [FileSystemItem]) {
        let itemsByID = Dictionary(uniqueKeysWithValues: model.explorerVisibleItems.map { ($0.id, $0) })
        let partition = TreemapLayoutEngine.partition(
            model.explorerVisibleItems.map { TreemapValue(id: $0.id, weight: $0.allocatedSize) },
            maximumVisibleItems: 60,
            minimumVisibleFraction: 0.003
        )
        return (
            partition.visible.compactMap { itemsByID[$0.id] },
            partition.grouped.compactMap { itemsByID[$0.id] }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            explorerHeader
            Divider()
            if model.explorerIsLoading && model.explorerItems.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Lecture du dossier…").font(.headline)
                    if model.isScanning { Text("Les tailles se précisent pendant l’analyse.").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.explorerDisplayMode == .grid {
                tileGrid
            } else {
                ExplorerListTable(items: model.explorerVisibleItems)
            }
            explorerSelectionBar
        }
        .task {
            if model.explorerCategoryContext == nil,
               model.currentDirectory == nil || model.currentDirectory == model.selectedVolume?.url {
                model.loadExplorerRoot()
            }
        }
    }

    private var explorerHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                if let volume = model.selectedVolume {
                    Button {
                        model.loadExplorerDirectory(volume.url)
                    } label: {
                        Label(volume.name, systemImage: "internaldrive.fill")
                    }
                    .buttonStyle(.plain)
                    if let context = model.explorerCategoryContext {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        Label(context.category.rawValue, systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.headline)
                    } else if let current = model.currentDirectory {
                        ForEach(Array(relativeComponents(root: volume.url, current: current).enumerated()), id: \.offset) { index, component in
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            Button(component) {
                                let target = relativeComponents(root: volume.url, current: current)
                                    .prefix(index + 1)
                                    .reduce(volume.url) { $0.appendingPathComponent($1, isDirectory: true) }
                                model.loadExplorerDirectory(target)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                if model.isScanning {
                    Label("Analyse en cours", systemImage: "waveform.path.ecg")
                        .font(.caption.bold()).foregroundStyle(.orange)
                }
                Picker("Affichage", selection: $model.explorerDisplayMode) {
                    ForEach(ExplorerDisplayMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode == .grid ? "square.grid.3x3" : "list.bullet").tag(mode)
                    }
                }
                .pickerStyle(.segmented).frame(width: 180)
                Button("Recharger", systemImage: "arrow.clockwise") {
                    if model.explorerCategoryContext != nil {
                        model.refreshCategoryExplorer()
                    } else {
                        model.loadExplorerDirectory(model.currentDirectory ?? model.selectedVolume?.url ?? URL(fileURLWithPath: "/"))
                    }
                }
            }

            HStack {
                Picker("Taille", selection: $model.sizeFilter) {
                    ForEach(SizeFilter.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 105)
                if let context = model.explorerCategoryContext {
                    Text("\(context.knownItemCount.formatted()) principaux fichiers affichés sur \(context.totalFileCount.formatted()) classés")
                        .font(.callout)
                    Button("Explorer la racine filtrée") { model.exploreCategoryAtRoot() }
                        .buttonStyle(.link)
                } else {
                    Picker("Catégorie", selection: $model.categoryFilter) {
                        Text("Toutes catégories").tag(ItemCategory?.none)
                        ForEach(ItemCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(width: 210)
                }
                Spacer()
                Text("\(model.explorerVisibleItems.count.formatted()) éléments · \(ByteCountFormatter.storage.string(fromByteCount: model.explorerVisibleItems.reduce(0) { $0 + $1.allocatedSize }))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let context = model.explorerCategoryContext {
                HStack(spacing: 10) {
                    Image(systemName: context.reportIsComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(context.reportIsComplete ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.reportIsComplete
                             ? "Principaux contributeurs connus dans tout le volume"
                             : "Aperçu provisoire — l’analyse ou le rapport n’est pas complet")
                            .font(.caption.bold())
                        Text("Cette liste réunit les principaux fichiers conservés par le rapport et le Top global, pas seulement les enfants de la racine.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteCountFormatter.storage.string(fromByteCount: context.totalAllocatedBytes))
                            .font(.headline).monospacedDigit()
                        Text("total classé · \(ByteCountFormatter.storage.string(fromByteCount: context.knownAllocatedBytes)) affichés")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background((context.reportIsComplete ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var tileGrid: some View {
        let split = splitItems
        let showingSmallItems = model.explorerShowsSmallItems && !split.small.isEmpty
        let displayedItems = showingSmallItems ? split.small : split.visible
        return VStack(spacing: 0) {
            if showingSmallItems {
                HStack(spacing: 10) {
                    Button("Retour à la carte principale", systemImage: "chevron.left") {
                        withAnimation(.snappy) { model.explorerShowsSmallItems = false }
                    }
                    .buttonStyle(.borderless)
                    Divider().frame(height: 16)
                    Text("\(split.small.count.formatted()) petits éléments, agrandis relativement pour rester explorables")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            ExplorerTreemapCanvas(
                items: displayedItems,
                groupedItems: showingSmallItems ? [] : split.small,
                totalBytes: totalBytes
            )
            .padding(18)
        }
        .overlay {
            if model.explorerVisibleItems.isEmpty && !model.explorerIsLoading {
                if let context = model.explorerCategoryContext {
                    ContentUnavailableView(
                        "Aucun contributeur conservé",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(context.reportIsComplete
                            ? "La catégorie ne contient aucun fichier connu correspondant aux filtres."
                            : "Le rapport est incomplet. Poursuivez ou relancez l’analyse pour remplir cette catégorie.")
                    )
                } else {
                    ContentUnavailableView("Dossier vide ou inaccessible", systemImage: "folder", description: Text(model.explorerIssues.first?.message ?? "Aucun élément ne correspond aux filtres."))
                }
            }
        }
    }

    @ViewBuilder private var explorerSelectionBar: some View {
        if !model.selectedItems.isEmpty {
            HStack {
                Text("\(model.selectedItems.count) sélectionné(s) · \(ByteCountFormatter.storage.string(fromByteCount: model.selectedBytes))")
                Spacer()
                Button("Finder") { if let first = model.selectedItems.first { model.reveal(first) } }
                Button("Mettre à la Corbeille", role: .destructive) { model.requestTrashSelection() }
                    .disabled(model.selectedItems.contains { !$0.isTrashable })
            }
            .padding(10).background(.bar)
        }
    }

    private func relativeComponents(root: URL, current: URL) -> [String] {
        let rootParts = root.standardizedFileURL.pathComponents
        let currentParts = current.standardizedFileURL.pathComponents
        return Array(currentParts.dropFirst(min(rootParts.count, currentParts.count)))
    }
}

private struct ExplorerTreemapNode: Identifiable {
    static let smallGroupID = "__storagescope_treemap_small_items__"

    let id: String
    let item: FileSystemItem?
    let groupedItems: [FileSystemItem]

    init(item: FileSystemItem) {
        id = item.id
        self.item = item
        groupedItems = []
    }

    init(groupedItems: [FileSystemItem]) {
        id = Self.smallGroupID
        item = nil
        self.groupedItems = groupedItems
    }

    var allocatedSize: Int64 {
        item?.allocatedSize ?? groupedItems.reduce(0) { $0 + $1.allocatedSize }
    }
}

private struct ExplorerTreemapCanvas: View {
    let items: [FileSystemItem]
    let groupedItems: [FileSystemItem]
    let totalBytes: Int64

    private var nodes: [ExplorerTreemapNode] {
        var result = items.map(ExplorerTreemapNode.init(item:))
        if !groupedItems.isEmpty { result.append(ExplorerTreemapNode(groupedItems: groupedItems)) }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            let nodeValues = layoutValues(for: nodes)
            let tiles = TreemapLayoutEngine.layout(
                nodeValues,
                in: TreemapRect(x: 0, y: 0, width: proxy.size.width, height: proxy.size.height)
            )
            let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    if let node = nodesByID[tile.id], tile.rect.area > 0 {
                        let spacing = min(3, max(0.5, min(tile.rect.width, tile.rect.height) / 12))
                        let width = max(0, tile.rect.width - spacing * 2)
                        let height = max(0, tile.rect.height - spacing * 2)

                        Group {
                            if let item = node.item {
                                ExplorerTreemapTile(
                                    item: item,
                                    totalBytes: totalBytes,
                                    width: width,
                                    height: height
                                )
                            } else {
                                ExplorerSmallItemsTile(
                                    items: node.groupedItems,
                                    width: width,
                                    height: height
                                )
                            }
                        }
                        .frame(width: width, height: height)
                        .offset(x: tile.rect.x + spacing, y: tile.rect.y + spacing)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Carte proportionnelle du stockage")
    }

    private func layoutValues(for nodes: [ExplorerTreemapNode]) -> [TreemapValue] {
        let realTotal = nodes.reduce(Int64(0)) { $0 + $1.allocatedSize }
        if realTotal == 0 {
            return nodes.map { TreemapValue(id: $0.id, weight: 1) }
        }
        let minimumGroupWeight = max(1, realTotal / 125)
        let zeroCount = max(1, nodes.count(where: { $0.allocatedSize == 0 }))
        // Unknown sizes are often folders whose index is still being finalized.
        // Give them at most ~1% of the local map collectively so they remain
        // clickable without materially distorting measured proportions.
        let minimumPendingWeight = max(1, realTotal / Int64(zeroCount * 100))
        return nodes.map { node in
            let weight: Int64
            if node.id == ExplorerTreemapNode.smallGroupID {
                weight = max(node.allocatedSize, minimumGroupWeight)
            } else if node.allocatedSize == 0 {
                weight = minimumPendingWeight
            } else {
                weight = node.allocatedSize
            }
            return TreemapValue(id: node.id, weight: weight)
        }
    }
}

private struct ExplorerTreemapTile: View {
    @EnvironmentObject private var model: AppModel
    let item: FileSystemItem
    let totalBytes: Int64
    let width: Double
    let height: Double

    private var fraction: Double { min(1, Double(item.allocatedSize) / Double(max(1, totalBytes))) }
    private var selected: Bool { model.selectedIDs.contains(item.id) }
    private var minimumDimension: Double { min(width, height) }
    private var cornerRadius: Double { min(14, max(3, minimumDimension * 0.09)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(selected ? Color.accentColor.opacity(0.22) : color.opacity(0.18))
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(selected ? Color.accentColor : color.opacity(0.45), lineWidth: selected ? 2 : 1)

            if width >= 48, height >= 28 {
                VStack(alignment: .leading, spacing: minimumDimension > 100 ? 7 : 3) {
                    HStack(spacing: 5) {
                        if minimumDimension >= 42 {
                            Image(systemName: icon)
                                .foregroundStyle(item.isDirectory ? .blue : color)
                        }
                        Text(item.name)
                            .font(minimumDimension > 95 ? .headline : .caption.bold())
                            .lineLimit(height > 90 ? 2 : 1)
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }
                    if width >= 92, height >= 60 {
                        Text(item.allocatedSize > 0 ? ByteCountFormatter.storage.string(fromByteCount: item.allocatedSize) : "Analyse en cours")
                            .font(minimumDimension > 115 ? .title3.bold() : .caption.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    if width >= 125, height >= 92 {
                        Text(fraction.formatted(.percent.precision(.fractionLength(fraction < 0.01 ? 1 : 0))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(min(12, max(4, minimumDimension * 0.08)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isPackage { model.open(item) } else { model.activate(item) }
        }
        .onTapGesture {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                if selected { model.selectedIDs.remove(item.id) } else { model.selectedIDs.insert(item.id) }
            } else {
                model.selectedIDs = [item.id]
            }
        }
        .help("\(item.name) — \(item.allocatedSize > 0 ? ByteCountFormatter.storage.string(fromByteCount: item.allocatedSize) : "taille en cours")")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(ByteCountFormatter.storage.string(fromByteCount: item.allocatedSize))")
        .contextMenu {
            if item.isDirectory && !item.isPackage { Button("Explorer") { model.activate(item) } }
            if item.isPackage { Button("Afficher le contenu du paquet") { model.showPackageContents(item) } }
            if item.isPackage && item.fileExtension == "app" {
                Button("Désinstaller proprement…") { model.prepareUninstall(item: item) }
            }
            Button("Afficher dans le Finder") { model.reveal(item) }
            Button("Ouvrir") { model.open(item) }
            Divider()
            if item.fileExtension != "app" {
                Button("Mettre à la Corbeille", role: .destructive) {
                    model.selectedIDs = [item.id]
                    model.requestTrashSelection()
                }
                .disabled(!item.isTrashable)
            }
        }
    }

    private var icon: String {
        if item.isPackage && item.fileExtension == "app" { return "app.fill" }
        if item.isDirectory { return "folder.fill" }
        return "doc.fill"
    }

    private var color: Color {
        switch item.category {
        case .application: .indigo
        case .applicationData: .purple
        case .image: .pink
        case .video: .red
        case .audio: .orange
        case .document: .blue
        case .archive: .brown
        case .development: .mint
        case .virtualMachine: .cyan
        case .backup: .teal
        case .mailAndMessages: .green
        case .cacheAndLogs: .yellow
        case .systemAndLibrary: .gray
        case .other: .secondary
        }
    }
}

private struct ExplorerSmallItemsTile: View {
    @EnvironmentObject private var model: AppModel
    let items: [FileSystemItem]
    let width: Double
    let height: Double

    private var bytes: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }
    private var minimumDimension: Double { min(width, height) }

    var body: some View {
        Button {
            model.selectedIDs.removeAll()
            withAnimation(.snappy) { model.explorerShowsSmallItems = true }
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: min(14, max(4, minimumDimension * 0.09)))
                    .fill(Color.secondary.opacity(0.16))
                RoundedRectangle(cornerRadius: min(14, max(4, minimumDimension * 0.09)))
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                VStack(alignment: .leading, spacing: 5) {
                    if minimumDimension > 48 { Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.secondary) }
                    Text("\(items.count.formatted()) petit\(items.count > 1 ? "s" : "") élément\(items.count > 1 ? "s" : "")")
                        .font(minimumDimension > 95 ? .headline : .caption.bold())
                        .lineLimit(2)
                    if width > 105, height > 66 {
                        Text(ByteCountFormatter.storage.string(fromByteCount: bytes))
                            .font(.caption.bold())
                            .monospacedDigit()
                    }
                    if width > 130, height > 96 {
                        Text("Ouvrir").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(min(12, max(4, minimumDimension * 0.08)))
            }
        }
        .buttonStyle(.plain)
        .help("Ouvrir les \(items.count) petits éléments")
        .accessibilityLabel("Ouvrir le groupe de \(items.count) petits éléments")
    }
}

private struct ExplorerListTable: View {
    @EnvironmentObject private var model: AppModel
    let items: [FileSystemItem]

    var body: some View {
        Table(items, selection: $model.selectedIDs) {
            TableColumn("Nom") { item in
                Label(item.name, systemImage: item.isDirectory ? (item.isPackage ? "shippingbox.fill" : "folder.fill") : "doc.fill")
                    .onTapGesture(count: 2) { item.isPackage ? model.open(item) : model.activate(item) }
                    .contextMenu {
                        if item.isDirectory && !item.isPackage { Button("Explorer") { model.activate(item) } }
                        if item.isPackage { Button("Afficher le contenu du paquet") { model.showPackageContents(item) } }
                        if item.isPackage && item.fileExtension == "app" { Button("Désinstaller proprement…") { model.prepareUninstall(item: item) } }
                        Button("Finder") { model.reveal(item) }
                        if item.fileExtension != "app" {
                            Button("Mettre à la Corbeille", role: .destructive) {
                                model.selectedIDs = [item.id]
                                model.requestTrashSelection()
                            }.disabled(!item.isTrashable)
                        }
                    }
            }
            TableColumn("Sur disque") { Text(ByteCountFormatter.storage.string(fromByteCount: $0.allocatedSize)).monospacedDigit() }.width(110)
            TableColumn("Catégorie") { Text($0.category.rawValue) }.width(150)
            TableColumn("Modification") { Text($0.modificationDate?.formatted(date: .numeric, time: .omitted) ?? "—") }.width(110)
        }
    }
}
