import AppKit
import Combine
import StorageCore
import SwiftUI

/// Fixed-height AppKit cells deliberately contain no NSHostingView. macOS 27 can
/// recursively invalidate the ideal heights of SwiftUI.Table's hosted rows when
/// a category replaces the previous content during a window layout transaction.
@MainActor
struct NativeFileTable: NSViewRepresentable {
    enum Mode: Equatable { case overview, explorer }
    @EnvironmentObject private var model: AppModel
    let items: [FileSystemItem]
    let mode: Mode

    func makeCoordinator() -> Coordinator { Coordinator(model: model, mode: mode) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let table = FileRowsTable()
        table.rowHeight = max(28, NSFont.preferredFont(forTextStyle: .body).pointSize + 12)
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let columns: [(String, String, CGFloat)] = mode == .explorer
            ? [("name", "Nom", 290), ("allocated", "Sur disque", 120), ("category", "Catégorie", 150), ("date", "Modification", 110)]
            : [("name", "Nom", 240), ("allocated", "Sur disque", 110), ("logical", "Logique", 100), ("category", "Type", 150), ("path", "Emplacement", 260), ("date", "Modification", 110)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? 160 : width
            column.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            column.isEditable = false; table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.activateRow(_:))
        table.menuProvider = { [weak coordinator = context.coordinator] row in coordinator?.menu(row: row) }
        table.hoverChanged = { [weak coordinator = context.coordinator] row in coordinator?.hover(row: row) }
        table.setAccessibilityLabel(mode == .explorer ? "Fichiers de l’explorateur" : "Fichiers de la vue d’ensemble")
        scroll.documentView = table; context.coordinator.table = table
        context.coordinator.observeExplorer()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.schedule(items: items, enabled: context.environment.isEnabled, hovered: model.explorerHoveredID)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.generation += 1
        coordinator.rowSubscription = nil
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
        coordinator.table?.menuProvider = nil; coordinator.table?.hoverChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        let mode: Mode
        weak var table: FileRowsTable?
        private(set) var items: [FileSystemItem] = []
        var generation = 0
        private var applying = false
        private var enabled = true
        var rowSubscription: AnyCancellable?
        private var pending: (items: [FileSystemItem], enabled: Bool, hovered: String?)?
        private var updateQueued = false
        init(model: AppModel, mode: Mode) { self.model = model; self.mode = mode }

        func observeExplorer() {
            guard mode == .explorer else { return }
            rowSubscription = model.explorerRowsDidChange.sink { [weak self] items in
                guard let self else { return }
                schedule(items: items, enabled: model.explorerPendingDirectory == nil, hovered: model.explorerHoveredID)
            }
        }

        func schedule(items incoming: [FileSystemItem], enabled: Bool, hovered: String?) {
            ExplorerPerformanceValidation.note("native-update")
            pending = (incoming, enabled, hovered)
            guard !updateQueued else { return }
            updateQueued = true
            let revision = generation
            // A representable's update can itself run inside AppKit layout. Defer
            // reloads and selection changes until that layout has finished.
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == revision, let table, let next = pending else { return }
                updateQueued = false; pending = nil
                let incoming = next.items, enabled = next.enabled, hovered = next.hovered
                ExplorerPerformanceValidation.note("native-apply")
                applying = true
                self.enabled = enabled; table.isEnabled = enabled
                if items != incoming {
                    let old = items; items = incoming
                    if old.count == incoming.count && zip(old, incoming).allSatisfy({ $0.0.id == $0.1.id }) {
                        let changed = IndexSet(incoming.indices.filter { old[$0] != incoming[$0] })
                        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                    } else { table.reloadData() }
                }
                let indexes = model.selectedIDs.isEmpty ? IndexSet() : IndexSet(items.enumerated().compactMap { model.selectedIDs.contains($0.element.id) ? $0.offset : nil })
                if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound {
                    let first = min(items.count, max(0, visible.location))
                    for row in first..<min(items.count, NSMaxRange(visible)) {
                        (table.rowView(atRow: row, makeIfNecessary: false) as? FileHoverRow)?.hovered = items[row].id == hovered
                    }
                }
                applying = false
                ExplorerPerformanceValidation.note("native-applied")
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row), let column else { return nil }
            let item = items[row], id = column.identifier.rawValue
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView) ?? makeCell(column.identifier, height: tableView.rowHeight)
            let text: String
            switch id {
            case "name": text = item.name
            case "allocated": text = item.hasKnownSize ? ByteCountFormatter.storage.string(fromByteCount: item.allocatedSize) : "Taille inconnue"
            case "logical": text = item.hasKnownSize ? ByteCountFormatter.storage.string(fromByteCount: item.logicalSize) : "Taille inconnue"
            case "category": text = item.category.rawValue
            case "date": text = item.modificationDate?.formatted(date: .numeric, time: .omitted) ?? "—"
            default: text = item.parentPath
            }
            cell.textField?.stringValue = text; cell.toolTip = id == "name" ? item.url.path : text
            cell.textField?.textColor = enabled ? .labelColor : .secondaryLabelColor
            if id == "allocated" || id == "logical" { cell.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
            if id == "name" || id == "category" {
                let symbol = id == "name" && item.isDirectory ? (item.isPackage ? "shippingbox.fill" : "folder.fill") : item.category.symbol
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.category.rawValue)
            } else { cell.imageView?.image = nil }
            cell.setAccessibilityLabel(text)
            return cell
        }
        private func makeCell(_ id: NSUserInterfaceItemIdentifier, height: CGFloat) -> NSTableCellView {
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: height))
            cell.identifier = id
            let hasIcon = id.rawValue == "name" || id.rawValue == "category"
            let field = NSTextField(labelWithString: "")
            field.font = .preferredFont(forTextStyle: .body)
            let textHeight = min(height, (field.font?.pointSize ?? 13) + 6)
            field.frame = NSRect(x: hasIcon ? 30 : 5, y: (height - textHeight) / 2, width: hasIcon ? 205 : 230, height: textHeight)
            field.autoresizingMask = [.width]; field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(field); cell.textField = field
            if hasIcon {
                let image = NSImageView(frame: NSRect(x: 7, y: (height - 16) / 2, width: 16, height: 16))
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image); cell.imageView = image
            }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table, enabled else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table, table.dataSource === self,
                      ids.isSubset(of: Set(items.map(\.id))), model.selectedIDs != ids else { return }
                model.selectedIDs = ids
            }
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = FileHoverRow()
            view.hovered = items.indices.contains(row) && items[row].id == model.explorerHoveredID
            return view
        }
        func hover(row: Int) {
            guard mode == .explorer else { return }
            let id = items.indices.contains(row) ? items[row].id : nil
            if model.explorerHoveredID != id { model.explorerHoveredID = id }
        }
        @objc func activateRow(_ sender: Any?) {
            guard let table, enabled, items.indices.contains(table.clickedRow) else { return }
            let item = items[table.clickedRow]
            if mode == .explorer && item.isPackage { model.open(item) } else { model.activate(item) }
        }
        func menu(row: Int) -> NSMenu? {
            guard enabled, items.indices.contains(row) else { return nil }
            let item = items[row], menu = NSMenu()
            func add(_ title: String, _ action: FileRowAction.Kind, allowed: Bool = true) {
                let entry = NSMenuItem(title: title, action: #selector(performMenu(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = FileRowAction(item: item, kind: action)
                entry.isEnabled = allowed; menu.addItem(entry)
            }
            menu.autoenablesItems = false
            if item.isDirectory && !item.isPackage { add("Explorer", .explore) }
            if item.isPackage { add("Afficher le contenu du paquet", .package) }
            if item.fileExtension == "app" && item.isPackage { add("Désinstaller proprement…", .uninstall, allowed: !model.operationsAreBusy) }
            add("Ouvrir", .open); add("Ouvrir le dossier", .folder); add("Afficher dans le Finder", .reveal)
            menu.addItem(.separator()); add("Copier le chemin", .copyPath); add("Copier le nom", .copyName)
            if item.fileExtension != "app" {
                menu.addItem(.separator()); add("Mettre à la corbeille", .trash, allowed: item.isTrashable && !model.operationsAreBusy)
            }
            return menu
        }
        @objc private func performMenu(_ sender: NSMenuItem) {
            guard enabled, let action = sender.representedObject as? FileRowAction,
                  items.contains(where: { $0.id == action.item.id }) else { return }
            let item = action.item
            switch action.kind {
            case .explore: model.activate(item)
            case .package: model.showPackageContents(item)
            case .open: model.open(item)
            case .folder: NSWorkspace.shared.open(item.isDirectory ? item.url : item.url.deletingLastPathComponent())
            case .reveal: model.reveal(item)
            case .copyPath: model.copyPath(item)
            case .copyName: model.copyName(item)
            case .uninstall: model.prepareUninstall(item: item)
            case .trash: model.selectedIDs = [item.id]; model.requestTrashSelection()
            }
        }
    }
}

@MainActor
private final class FileHoverRow: NSTableRowView {
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if hovered && !isSelected { NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); bounds.fill() }
    }
}

private final class FileRowAction: NSObject {
    enum Kind { case explore, package, open, folder, reveal, copyPath, copyName, uninstall, trash }
    let item: FileSystemItem
    let kind: Kind
    init(item: FileSystemItem, kind: Kind) { self.item = item; self.kind = kind }
}

@MainActor
final class FileRowsTable: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    var hoverChanged: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        let target = clicked >= 0 ? clicked : selectedRow
        guard target >= 0, isEnabled else { return nil }
        if !selectedRowIndexes.contains(target) { selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false) }
        return menuProvider?(target)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) { hoverChanged?(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(-1) }
}
