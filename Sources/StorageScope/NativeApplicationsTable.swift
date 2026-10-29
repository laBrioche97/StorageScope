import AppKit
import StorageCore
import SwiftUI

/// Reusable fixed-height AppKit rows. No hosted SwiftUI view participates in row sizing.
@MainActor
struct NativeApplicationsTable: NSViewRepresentable {
    let rows: [ApplicationRowPresentation]
    let icons: [String: NSImage]
    @Binding var selection: String?
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let table = InventoryTable(); table.rowHeight = 64; table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 8, height: 3); table.backgroundColor = .clear
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        for (id, title, width) in [("name", "Application", 290.0), ("size", "Espace sur disque", 170.0), ("source", "Source", 105.0), ("permission", "Désinstallation", 160.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "name" ? 190 : width; column.isEditable = false
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.activate)
        table.menuProvider = { [weak coordinator = context.coordinator] row in coordinator?.menu(row) }
        table.setAccessibilityLabel("Applications installées, tailles et autorisations")
        scroll.documentView = table; context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.revision += 1; coordinator.iconTasks.values.forEach { $0.cancel() }
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil; coordinator.table?.menuProvider = nil
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeApplicationsTable
        weak var table: InventoryTable?
        var rows: [ApplicationRowPresentation] = []
        var revision = 0
        var applying = false
        var iconTasks: [String: Task<Void, Never>] = [:]
        var iconRevision: UUID?
        init(_ parent: NativeApplicationsTable) { self.parent = parent }
        func update(_ next: NativeApplicationsTable) {
            parent = next; revision += 1; let current = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, current == revision, let table else { return }
                applying = true
                let old = rows; rows = next.rows
                let revalidateIcons = iconRevision != next.model.applicationIconRevision
                iconRevision = next.model.applicationIconRevision
                if old.map(\.id) != rows.map(\.id) { table.reloadData() }
                else {
                    let changed = IndexSet(rows.indices.filter { old[$0] != rows[$0] })
                    if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
                    let range = table.rows(in: table.visibleRect)
                    if range.location != NSNotFound {
                        for index in max(0, range.location)..<min(rows.count, NSMaxRange(range)) {
                            if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView {
                                cell.imageView?.image = next.icons[rows[index].id] ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application")
                            }
                        }
                    }
                }
                let index = rows.firstIndex { $0.id == next.selection }
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound {
                    let indexes = max(0, visible.location)..<min(rows.count, NSMaxRange(visible))
                    next.model.inventory.visibleApplicationIDs = Set(indexes.map { rows[$0].id })
                    if revalidateIcons {
                        for index in indexes where iconTasks[rows[index].id] == nil {
                            let app = rows[index].application
                            iconTasks[app.id] = Task { [weak self] in
                                await next.model.loadApplicationIcon(app); self?.iconTasks[app.id] = nil
                            }
                        }
                    }
                }
                let indexes = index.map { IndexSet(integer: $0) } ?? []
                if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
                applying = false
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column else { return nil }
            let item = rows[row], id = column.identifier.rawValue
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView) ?? makeCell(column.identifier)
            let text = switch id { case "name": item.application.displayName; case "size": item.size; case "source": item.source; default: item.permission }
            cell.textField?.stringValue = text; cell.toolTip = id == "name" ? item.application.bundleURL.path : item.application.eligibility.explanation ?? text
            cell.setAccessibilityLabel(text)
            if id == "name" {
                (cell.viewWithTag(10) as? NSTextField)?.stringValue = item.application.version.map { "Version " + $0 } ?? "Application Mac"
                cell.imageView?.image = parent.icons[item.id] ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application")
                if parent.icons[item.id] == nil && iconTasks[item.id] == nil {
                    iconTasks[item.id] = Task { [weak self] in
                        guard let self else { return }
                        await parent.model.loadApplicationIcon(item.application)
                        iconTasks[item.id] = nil
                    }
                }
            }
            return cell
        }
        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 290, height: 64)); cell.identifier = id
            let name = id.rawValue == "name"
            let label = NSTextField(labelWithString: ""); label.font = name ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
            label.frame = NSRect(x: name ? 62 : 5, y: name ? 32 : 22, width: name ? 222 : 280, height: 18)
            label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingTail; label.autoresizingMask = .width
            cell.addSubview(label); cell.textField = label
            if name {
                let image = NSImageView(frame: NSRect(x: 8, y: 10, width: 42, height: 42)); image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image); cell.imageView = image
                let detail = NSTextField(labelWithString: ""); detail.tag = 10; detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
                detail.frame = NSRect(x: 62, y: 13, width: 222, height: 16); detail.autoresizingMask = .width; detail.lineBreakMode = .byTruncatingTail
                cell.addSubview(detail)
            }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            let selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            DispatchQueue.main.async { [weak self] in self?.parent.selection = selection }
        }
        @objc func activate() {
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            parent.model.prepareUninstall(rows[table.clickedRow].application)
        }
        func menu(_ index: Int) -> NSMenu? {
            guard rows.indices.contains(index) else { return nil }
            let menu = NSMenu(); let app = rows[index].application
            for (title, selector) in [("Afficher dans le Finder", #selector(reveal(_:))), ("Vérifier la désinstallation…", #selector(uninstall(_:)))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.representedObject = app.id; menu.addItem(item)
            }
            return menu
        }
        @objc func reveal(_ sender: NSMenuItem) { if let app = application(sender) { NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL]) } }
        @objc func uninstall(_ sender: NSMenuItem) { if let app = application(sender) { parent.model.prepareUninstall(app) } }
        private func application(_ sender: NSMenuItem) -> InstalledApplication? { rows.first { $0.id == sender.representedObject as? String }?.application }
    }
}

@MainActor final class InventoryTable: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }; selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return menuProvider?(index)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 110 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)), selectedRow >= 0 {
            menuProvider?(selectedRow)?.popUp(positioning: nil, at: NSPoint(x: 30, y: rect(ofRow: selectedRow).midY), in: self)
        } else { super.keyDown(with: event) }
    }
}
