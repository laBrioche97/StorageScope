import AppKit
import SwiftUI

/// Observe only the native table's clip view; never retain a cached visual tree.
struct ExplorerScrollMemory: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let path = model.currentDirectory?.path
        let offset = model.explorerScrollPosition
        DispatchQueue.main.async { coordinator.attach(from: nsView, path: path, offset: offset) }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.detach() }
    @MainActor final class Coordinator {
        let model: AppModel
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var path: String?
        init(model: AppModel) { self.model = model }
        func detach() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil; scroll = nil }
        func attach(from view: NSView, path: String?, offset: Double) {
            func find(_ parent: NSView) -> NSScrollView? {
                if let scroll = parent as? NSScrollView, scroll.documentView is NSTableView { return scroll }
                for child in parent.subviews { if let scroll = find(child) { return scroll } }
                return nil
            }
            var parent: NSView? = view
            var found: NSScrollView?
            for _ in 0..<6 { if let next = parent { found = find(next); if found != nil { break }; parent = next.superview } }
            guard let found else { return }
            if scroll !== found {
                detach(); scroll = found; found.contentView.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: found.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.model.currentDirectory?.path == self.path, self.model.explorerPendingDirectory == nil, let scroll = self.scroll else { return }
                        self.model.explorerScrollPosition = scroll.contentView.bounds.origin.y
                    }
                }
            }
            if self.path != path {
                let firstAttachment = self.path == nil
                self.path = path
                if offset.isFinite { found.contentView.scroll(to: NSPoint(x: 0, y: offset)) }
                else if !firstAttachment, let table = found.documentView as? NSTableView, table.numberOfRows > 0 { table.scrollRowToVisible(0) }
                found.reflectScrolledClipView(found.contentView)
            }
        }
    }
}
