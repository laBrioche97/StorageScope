import AppKit
import Foundation

@MainActor enum ExplorerInteractionValidation {
    static func run(model: AppModel, window: NSWindow, root: URL, first: URL, destination: URL) async throws {
        model.loadExplorerDirectory(root)
        try await wait(model: model, directory: root)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        guard let button = find(window.contentView, path: first.path), button.bounds.width > 20,
              let content = window.contentView else { throw failure("La bulle du dossier n’est pas un contrôle natif visible") }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        guard content.hitTest(content.convert(point, from: content.superview)) === button else { throw failure("Le clic au centre de la bulle est intercepté") }
        // Exercise real AppKit tracking and mouse dispatch, not performClick/model navigation.
        let now = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: now + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw failure("Impossible de créer les événements souris") }
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        try await wait(model: model, directory: first)
        guard model.canBrowseBack else { throw failure("Le clic n’a pas alimenté l’historique") }
        // Standard macOS keyboard history goes through the same local responder as swipes.
        guard let back = NSEvent.keyEvent(with: .keyDown, location: point, modifierFlags: .command, timestamp: now + 1, windowNumber: window.windowNumber, context: nil, characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33) else { throw failure("Événement clavier absent") }
        window.makeFirstResponder(button)
        NSApp.sendEvent(back)
        try await wait(model: model, directory: root)
        guard model.canBrowseForward else { throw failure("Le retour a perdu l’historique avant") }
        model.browseHistory(1)
        try await wait(model: model, directory: first)
        guard model.explorerDisplayMode == .bubbles else { throw failure("La navigation a changé le mode préféré") }
        let result: [String: Any] = ["actualMouseDownUp": true, "circularHitTesting": true, "keyboardBack": true, "forwardHistory": true, "modePreserved": true, "physicalTrackpadMeasured": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("macos-explorer-interaction.json"))
    }
    private static func wait(model: AppModel, directory: URL) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if model.currentDirectory?.path == directory.path && !model.explorerIsLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw failure("Navigation non terminée vers " + directory.path)
    }
    private static func find(_ view: NSView?, path: String) -> BubbleNativeButton? {
        guard let view else { return nil }
        if let button = view as? BubbleNativeButton, button.node?.path == path { return button }
        return view.subviews.lazy.compactMap { find($0, path: path) }.first
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "StorageScope.ExplorerInteraction", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
