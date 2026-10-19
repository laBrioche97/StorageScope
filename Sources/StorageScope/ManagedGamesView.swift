import AppKit
import StorageCore
import SwiftUI

struct ManagedGamesPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var games: [ManagedGame] = []
    @State private var selected: ManagedGame?
    @State private var message: String?
    @State private var loading = true
    private let adapter = LocalGameLibraryAdapter()

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
                if loading { ProgressView() }
                else if games.isEmpty { Text("Aucune bibliothèque reconnue sur ce Mac.").foregroundStyle(.secondary) }
                ForEach(games.filter { model.searchText.isEmpty || ($0.name + $0.provider.rawValue).localizedCaseInsensitiveContains(model.searchText) }) { game in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(game.name).font(.headline)
                                Text(game.provider.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Examiner") { NSWorkspace.shared.activateFileViewerSelecting([game.installURL]) }
                            Button(game.canUninstall ? "Désinstaller…" : "Voir la méthode") { selected = game }
                                .disabled(model.operationsAreBusy)
                        }
                        Text(game.installURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
                if model.gameUninstallIsWorking { ProgressView("En attente de la désinstallation officielle…") }
                if let message { Text(message).font(.callout).textSelection(.enabled) }
            }.padding(8)
        }
        .task { await reload() }
        .alert("Désinstallation du jeu", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let game = selected, game.canUninstall { Button("Continuer avec le moteur officiel") { Task { await uninstall(game) } } }
            Button("Fermer", role: .cancel) { selected = nil }
        } message: { Text(selected?.explanation ?? "") }
    }

    @MainActor private func reload() async { loading = true; games = await adapter.detect(); loading = false }
    @MainActor private func uninstall(_ game: ManagedGame) async {
        selected = nil
        guard !model.operationsAreBusy, await adapter.prepare(game), !model.operationsAreBusy else { message = "L’installation a changé ou sa méthode n’est pas disponible. Actualisez la liste."; return }
        model.gameUninstallIsWorking = true
        defer { model.gameUninstallIsWorking = false }
        do { try OperationJournal.append(operation: "désinstallation officielle", path: game.installURL.path, status: "préparé") }
        catch { message = "L’historique local n’est pas accessible. Aucun désinstalleur n’a été lancé."; return }
        guard await adapter.execute(game) else { message = "Le launcher officiel n’a pas pu être ouvert. Aucun fichier n’a été supprimé."; return }
        for _ in 0..<60 {
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
        message = "Le moteur officiel a été ouvert ; la désinstallation n’est pas encore confirmée. Terminez-la puis actualisez la liste."
        try? OperationJournal.append(operation: "désinstallation officielle", path: game.installURL.path, status: "à vérifier")
    }
}
