import AppKit
import SwiftUI

/// Window resize events do not depend on the SwiftUI subtree's preferred size.
/// Publish only a mode change, on the following main-loop turn, never in layout.
@MainActor
struct WindowLayoutObserver: NSViewRepresentable {
    let onModeChange: (Bool) -> Void
    func makeNSView(context: Context) -> WindowLayoutProbe {
        let view = WindowLayoutProbe()
        view.onModeChange = onModeChange
        return view
    }
    func updateNSView(_ view: WindowLayoutProbe, context: Context) {
        view.onModeChange = onModeChange
        view.scheduleReport()
    }
    static func dismantleNSView(_ view: WindowLayoutProbe, coordinator: ()) { view.stopObserving() }
}

@MainActor
final class WindowLayoutProbe: NSView {
    var onModeChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastMode: Bool?
    private var generation = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReport() }
            })
        }
        scheduleReport()
    }
    func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); generation += 1; lastMode = nil
    }
    func scheduleReport() {
        guard let window else { return }
        let compact = window.contentLayoutRect.width < 950
        guard compact != lastMode else { return }
        generation += 1
        let scheduled = generation
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, generation == scheduled else { return }
            guard (window.contentLayoutRect.width < 950) == compact else { scheduleReport(); return }
            lastMode = compact
            onModeChange?(compact)
        }
    }
}
