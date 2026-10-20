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
        model.searchText = "Applications"; model.sidebar = .explorer
        precondition(model.searchText.isEmpty)
        model.searchText = "Dossiers"; model.sidebar = .applications
        precondition(model.searchText == "Applications")
        model.sidebar = .explorer; precondition(model.searchText == "Dossiers"); model.resetSectionFilters()
        let weights: [Int64] = [40, 25, 15, 10, 5]
        model.explorerItems = weights.enumerated().map { index, bytes in
            FileSystemItem(url: URL(fileURLWithPath: "/Volumes/Test/Item-\(index)"), name: ["Applications", "Documents", "Jeux", "Vidéo.mp4", "Archives.zip"][index], logicalSize: bytes * 1_073_741_824, allocatedSize: bytes * 1_073_741_824, isDirectory: index < 3, category: index == 3 ? .video : index == 4 ? .archive : .other, sizeIsKnown: true)
        }
        model.bubbleFrame = try ExplorerBubbleLayout.frame(path: "/Volumes/Test", items: model.explorerItems, total: 95 * 1_073_741_824, partial: false)
        precondition(model.bubbleFrame?.folders.count == 5 && model.bubbleFrame?.folders.allSatisfy { $0.depth == 0 } == true)
        model.bubbleMessage = "Tailles mesurées · Dossiers et fichiers de ce niveau"
        model.currentDirectory = URL(fileURLWithPath: "/Volumes/Test")
        for (width, height, suffix) in [(1120.0, 800.0, "large"), (740.0, 560.0, "small")] {
        model.bubbleFrame = try ExplorerBubbleLayout.frame(path: "/Volumes/Test", items: model.explorerItems, total: 95 * 1_073_741_824, partial: false, availableDiameter: height < 600 ? 180 : 400)
        for dark in [false, true] {
            for scale in [1.0, 2.0] {
                let view = ContentView().environmentObject(model).environmentObject(SoftwareUpdates())
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: width, height: height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width * scale, height: height * scale, alignment: .topLeading)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width * scale, height: height * scale), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: width * scale, height: height * scale)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: destination.appendingPathComponent("macos-bubbles-\(suffix)-\(dark ? "dark" : "light")-\(Int(scale * 100)).png"))
                window.close()
            }
        }
        }
        print("PASS native macOS bubble rendering at 100/200%, light/dark, cached icons and initial navigation")
    }
}
