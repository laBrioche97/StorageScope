import AppKit
import StorageCore
import SwiftUI

/// Offscreen native rendering, invoked only by the explicit CI validation command.
@MainActor
enum NativeInterfaceValidation {
    static func run() async throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments.last ?? "/tmp/storagescope-ui")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let model = AppModel()
        precondition(model.sidebar == .applications && SidebarSection.allCases.first == .applications)
        let source = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let first = model.iconCache.image(for: source)
        precondition(first === model.iconCache.image(for: source), "Session logo cache must reuse decoded images")
        let weights: [Double] = [40, 25, 15, 10, 5]
        let circles = CirclePacking.pack(weights)
        var nodes = circles.enumerated().map { index, circle in
            FolderBubble(path: "/Volumes/Test/Folder-\(index)", name: ["Applications", "Documents", "Jeux", "Vidéos", "Archives"][index], bytes: Int64(weights[index] * 1_073_741_824), circle: PackedCircle(x: circle.x * 0.9, y: circle.y * 0.9, radius: circle.radius * 0.9), depth: 0)
        }
        let parent = nodes[0]
        let childCircle = PackedCircle(x: parent.circle.x, y: parent.circle.y, radius: parent.circle.radius * 0.63)
        nodes.append(FolderBubble(path: parent.path + "/Sous-dossier", name: "Sous-dossier", bytes: parent.bytes / 2, circle: childCircle, depth: 1, parentBytes: parent.bytes))
        model.bubbleFrame = FolderBubbleFrame(folders: nodes, totalBytes: 100 * 1_073_741_824, directFileBytes: 5 * 1_073_741_824, isPartial: false, updatedAt: Date())
        model.bubbleMessage = "Tailles identifiées · Cliquez sur un dossier pour l’ouvrir."
        model.currentDirectory = URL(fileURLWithPath: "/Volumes/Test")
        for dark in [false, true] {
            for scale in [1.0, 2.0] {
                let view = FolderBubblesView().environmentObject(model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: 740, height: 560)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: 740 * scale, height: 560 * scale, alignment: .topLeading)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740 * scale, height: 560 * scale), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: 740 * scale, height: 560 * scale)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: destination.appendingPathComponent("macos-bubbles-\(dark ? "dark" : "light")-\(Int(scale * 100)).png"))
                window.close()
            }
        }
        print("PASS native macOS bubble rendering at 100/200%, light/dark, cached icons and initial navigation")
    }
}
