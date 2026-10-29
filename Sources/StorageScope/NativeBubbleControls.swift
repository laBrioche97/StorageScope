import AppKit
import StorageCore
import SwiftUI

struct NativeBubbleControls: NSViewRepresentable {
    let model: AppModel
    let nodes: [FolderBubble]
    let enabled: Bool
    func makeNSView(context: Context) -> BubbleControlContainer { BubbleControlContainer() }
    func updateNSView(_ view: BubbleControlContainer, context: Context) { view.update(model: model, nodes: nodes, enabled: enabled) }
}

@MainActor final class BubbleControlContainer: NSView {
    override var isFlipped: Bool { true }
    private var controls: [String: BubbleNativeButton] = [:]
    func update(model: AppModel, nodes: [FolderBubble], enabled: Bool) {
        let ids = Set(nodes.map(\.id))
        for id in Array(controls.keys) where !ids.contains(id) { controls.removeValue(forKey: id)?.removeFromSuperview() }
        for node in nodes {
            let button = controls[node.id] ?? BubbleNativeButton()
            if button.superview == nil { controls[node.id] = button; addSubview(button) }
            button.model = model; button.node = node; button.isEnabled = enabled
            button.setAccessibilityLabel(node.name)
            button.setAccessibilityValue(ByteCountFormatter.storage.string(fromByteCount: node.bytes))
            button.toolTip = node.name + "\n" + node.path + "\n" + ByteCountFormatter.storage.string(fromByteCount: node.bytes) + (node.parentBytes > 0 ? String(format: " · %.1f %% du dossier parent", Double(node.bytes) * 100 / Double(node.parentBytes)) : "")
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for button in controls.values { if let node = button.node { button.frame = BubbleGeometry.rect(node, size: bounds.size) } }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        // No full-canvas transparent target: gaps and another circle's rectangular
        // corners must never intercept its neighbour's mouse events.
        let local = convert(point, from: superview)
        for button in controls.values { if let hit = button.hitTest(local) { return hit } }
        return nil
    }
}

@MainActor final class BubbleNativeButton: NSButton {
    weak var model: AppModel?
    var node: FolderBubble?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""; isBordered = false; setButtonType(.momentaryPushIn)
        target = self; action = #selector(openBubble)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)); circle.lineWidth = 3; circle.stroke()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = min(bounds.width, bounds.height) / 2
        let dx = local.x - bounds.midX, dy = local.y - bounds.midY
        return !isHidden && isEnabled && dx * dx + dy * dy <= radius * radius ? self : nil
    }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { model?.explorerHoveredID = node?.path }
    override func mouseExited(with event: NSEvent) { if model?.explorerHoveredID == node?.path { model?.explorerHoveredID = nil } }
    override func becomeFirstResponder() -> Bool { model?.explorerHoveredID = node?.path; needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    @objc func openBubble() { if let node { model?.openBubble(node) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node, !node.isAggregate else { return nil }
        model?.selectedIDs = [node.path]
        let menu = NSMenu()
        for (title, selector) in [("Ouvrir", #selector(openItem)), ("Afficher dans le Finder", #selector(reveal)), ("Copier le chemin", #selector(copyPath)), ("Mettre à la corbeille…", #selector(trash))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
            if selector == #selector(trash) { item.isEnabled = model?.operationsAreBusy == false }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { openBubble() }
        else if event.keyCode == 109 && event.modifierFlags.contains(.shift), let menu = menu(for: event) {
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        } else { super.keyDown(with: event) }
    }
    @objc private func openItem() { if let node { if node.isDirectory { openBubble() } else { NSWorkspace.shared.open(URL(fileURLWithPath: node.path)) } } }
    @objc private func reveal() { if let node { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) } }
    @objc private func copyPath() { if let node { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.path, forType: .string) } }
    @objc private func trash() { if let node, let item = model?.explorerItems.first(where: { $0.id == node.path }) { model?.requestTrash(items: [item]) } }
}
