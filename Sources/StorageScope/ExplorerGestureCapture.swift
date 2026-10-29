import AppKit
import SwiftUI

struct ExplorerGestureCapture: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> ExplorerGestureView { let view = ExplorerGestureView(); view.model = model; return view }
    func updateNSView(_ view: ExplorerGestureView, context: Context) { view.model = model }
    static func dismantleNSView(_ view: ExplorerGestureView, coordinator: ()) { view.removeMonitor() }
}

/// A local, window-scoped responder bridge. No global event monitoring or
/// Accessibility permission; it yields to horizontal scroll views before their edge.
@MainActor final class ExplorerGestureView: NSView {
    weak var model: AppModel?
    private var monitor: Any?
    private var tracking = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .otherMouseUp, .keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }
    func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; tracking = false }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, model.sidebar == .explorer, !model.choosingExplorerStorage, event.window === window else { return event }
        if event.type == .keyDown {
            if let editor = window?.firstResponder as? NSTextView, editor.isEditable { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                if event.charactersIgnoringModifiers == "[" && model.canBrowseBack { model.browseHistory(-1); return nil }
                if event.charactersIgnoringModifiers == "]" && model.canBrowseForward { model.browseHistory(1); return nil }
            }
            return event
        }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
        if event.type == .otherMouseUp {
            if event.buttonNumber == 3 && model.canBrowseBack { model.browseHistory(-1); return nil }
            if event.buttonNumber == 4 && model.canBrowseForward { model.browseHistory(1); return nil }
            return event
        }
        if event.type == .swipe {
            if event.deltaX > 0 && model.canBrowseBack { model.browseHistory(-1); return nil }
            if event.deltaX < 0 && model.canBrowseForward { model.browseHistory(1); return nil }
            return event
        }
        guard !tracking, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              event.hasPreciseScrollingDeltas, event.phase == .began,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.scrollingDeltaX != 0 else { return event }
        let back = event.scrollingDeltaX > 0
        guard back ? model.canBrowseBack : model.canBrowseForward else { return event }
        // A wide table/fil d'Ariane keeps scrolling normally until its boundary.
        var hit = window?.contentView?.hitTest(event.locationInWindow)
        while let view = hit {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.bounds.width > scroll.contentView.bounds.width + 1 {
                let origin = scroll.contentView.bounds.minX
                if back ? origin > 0 : origin < document.bounds.width - scroll.contentView.bounds.width - 1 { return event }
            }
            hit = view.superview
        }
        tracking = true
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: model.canBrowseForward ? -1 : 0, max: model.canBrowseBack ? 1 : 0) { [weak self, weak model] amount, phase, complete, _ in
            guard let self else { return }
            if complete {
                self.tracking = false
                guard !phase.contains(.cancelled), abs(amount) >= 0.99, let model, model.sidebar == .explorer else { return }
                let direction = amount > 0 ? -1 : 1
                if direction < 0 ? model.canBrowseBack : model.canBrowseForward { model.browseHistory(direction) }
            }
        }
        return nil
    }
}
