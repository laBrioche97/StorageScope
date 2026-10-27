import AppKit
import StorageCore
import SwiftUI

struct ManagedGamesPanel: View {
    @EnvironmentObject private var model: AppModel
    private var games: [ManagedGame] { model.managedGames }
    @State private var selected: ManagedGame?
    @State private var message: String?
    @State private var loading = true
    @State private var uninstallTask: Task<Void, Never>?
    @State private var source = "Toutes les sources"
    private var icons: [String: NSImage] { model.gameIcons }
    @State private var epicGuide: EpicGuideController?
    private var adapter: LocalGameLibraryAdapter { model.gameAdapter }

    private var filteredGames: [ManagedGame] {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ordered = model.sort == .name ? model.gamesByName : model.sort == .smallest ? model.gamesSmallest : model.gamesLargest
        return ordered.filter { game in
            (source == "Toutes les sources" || game.provider.rawValue == source) &&
            (model.sizeFilter == .all || (model.installationSize(at: game.installURL, declaredBytes: game.estimatedBytes).bytes ?? -1) >= model.sizeFilter.rawValue) &&
            (query.isEmpty || (game.name + " " + game.provider.rawValue + " " + game.installURL.path).lowercased().contains(query))
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Jeux et bibliothèques", systemImage: "gamecontroller.fill").font(.title2.bold())
                    Spacer()
                    Button("Actualiser") { Task { await reload() } }.disabled(model.gameUninstallIsWorking)
                }
                Text("Steam, Epic et installations Battle.net reconnues localement. Les autres jeux macOS apparaissent aussi parmi les applications. Aucun launcher ni compte en ligne n’est nécessaire pour l’inventaire.")
                    .font(.callout).foregroundStyle(.secondary)
                if loading && games.isEmpty { ProgressView() }
                else if games.isEmpty { Text("Aucune bibliothèque reconnue sur ce Mac.").foregroundStyle(.secondary) }
                Picker("Source", selection: $source) {
                    Text("Toutes les sources").tag("Toutes les sources")
                    ForEach(GameProvider.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                LazyVStack(alignment: .leading, spacing: 8) { ForEach(filteredGames) { game in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if let icon = icons[game.id] { Image(nsImage: icon).resizable().scaledToFit().frame(width: 32, height: 32) }
                            VStack(alignment: .leading) {
                                Text(game.name).font(.headline)
                                Text(game.provider.rawValue).font(.caption).foregroundStyle(.secondary)
                                Text(model.installationSize(at: game.installURL, declaredBytes: game.estimatedBytes).label).font(.caption).monospacedDigit()
                            }
                            Spacer()
                            Button("Examiner") { NSWorkspace.shared.activateFileViewerSelecting([game.installURL]) }
                            Button(game.provider == .epic ? "Désinstaller avec Epic…" : game.canUninstall ? "Désinstaller…" : "Voir la méthode") {
                                if game.provider == .epic {
                                    let guide = EpicGuideController(game: game, model: model)
                                    epicGuide = guide; guide.showWindow(nil)
                                } else { selected = game }
                            }
                                .disabled(model.operationsAreBusy)
                        }
                        Text(game.installURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
                }
                if model.gameUninstallIsWorking {
                    HStack {
                        ProgressView("En attente de la désinstallation officielle…")
                        Button("Arrêter le suivi") { uninstallTask?.cancel() }
                    }
                    Text("Arrêter le suivi n’annule pas une désinstallation déjà acceptée dans le launcher.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.callout).textSelection(.enabled) }
            }.padding(8)
        }
        .onChange(of: model.applicationsAreLoading, initial: true) { _, value in loading = value }
        .alert("Désinstallation du jeu", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let game = selected, game.canUninstall { Button("Continuer avec le moteur officiel") { uninstallTask = Task { await uninstall(game) } } }
            Button("Fermer", role: .cancel) { selected = nil }
        } message: {
            Text(selected.map { model.installationSize(at: $0.installURL, declaredBytes: $0.estimatedBytes).label + "\n\n" + $0.explanation } ?? "")
        }
    }

    @MainActor private func reload() async {
        if model.isPreviewMode { loading = false; return }
        model.loadApplications()
    }
    @MainActor private func uninstall(_ game: ManagedGame) async {
        selected = nil
        guard !model.operationsAreBusy else { return }
        if let reason = await adapter.unavailabilityReason(game) { message = reason; return }
        guard !model.operationsAreBusy else { return }
        model.gameUninstallIsWorking = true
        defer { model.gameUninstallIsWorking = false }
        do { try OperationJournal.append(operation: "désinstallation officielle", path: game.installURL.path, status: "préparé") }
        catch { message = "L’historique local n’est pas accessible. Aucun désinstalleur n’a été lancé."; return }
        guard await adapter.execute(game) else { message = Task.isCancelled ? "Suivi annulé. Aucun fichier n’a été supprimé par StorageScope." : "Le launcher officiel n’a pas pu être ouvert. Aucun fichier n’a été supprimé."; return }
        for _ in 0..<150 {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { break }
            if await adapter.verify(game) {
                try? OperationJournal.append(operation: "désinstallation officielle", path: game.installURL.path, status: "confirmée")
                message = "Désinstallation confirmée. Les sauvegardes et fichiers personnels n’ont pas été nettoyés par StorageScope."
                await reload()
                model.refreshVolumes()
                return
            }
        }
        message = Task.isCancelled ? "Suivi annulé. Une désinstallation déjà acceptée dans le launcher peut continuer ; actualisez ensuite l’inventaire." : "Le moteur officiel a été ouvert ; la désinstallation n’est pas encore confirmée. Terminez-la puis actualisez la liste."
        try? OperationJournal.append(operation: "désinstallation officielle", path: game.installURL.path, status: Task.isCancelled ? "suivi annulé" : "à vérifier")
    }
}
