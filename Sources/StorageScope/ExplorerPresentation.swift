import AppKit
import StorageCore
import SwiftUI

/// Navigation changes update the explorer, never the whole application shell.
/// Coalesce a complete destination into one publication after its data is ready.
@MainActor final class ExplorerPresentation: ObservableObject {
    private var queued = false
    func invalidate() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false; objectWillChange.send()
        }
    }
    var currentDirectory: URL? = nil
    var explorerItems: [FileSystemItem] = []
    var explorerIssues: [ScanIssue] = []
    var explorerIsLoading: Bool = false
    var explorerLoaderVisible: Bool = false
    var explorerPendingDirectory: URL? = nil
    var explorerVisited: Int = 0
    var navigationRevision: UUID = UUID()
    var navigationBack: Bool = false
    var navigationAnchor: UnitPoint = .center
    var bubbleFrame: FolderBubbleFrame? = nil
    var bubbleIsLoading: Bool = false
    var explorerHoveredID: String? = nil
    var bubbleMessage: String = "Préparation du graphique…"
}
