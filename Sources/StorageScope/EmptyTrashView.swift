import AppKit
import StorageCore
import SwiftUI

struct EmptyTrashView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Corbeille", systemImage: "trash.fill").font(.title2.bold())
                Spacer()
                Button("Actualiser") { model.refreshTrashSummary(force: true) }
                    .disabled(model.trashSummaryIsLoading || model.emptyTrashStep == .running)
                Button("Fermer") { dismiss() }.disabled(model.emptyTrashStep == .running).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            Group {
                switch model.emptyTrashStep {
                case .inventory: inventoryStep
                case .confirmation: inventoryStep
                case .running: runningStep
                case .result: resultStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .interactiveDismissDisabled(model.emptyTrashStep == .running)
        .alert("Vider définitivement la Corbeille ?", isPresented: $confirming) {
            Button("Annuler", role: .cancel) {}
            Button("Vider définitivement", role: .destructive) { model.emptyTrashPermanently() }
        } message: {
            Text("\(model.trashInventory?.items.count ?? 0) élément(s) inventorié(s) · \(inventorySize). Corbeilles de votre compte sur les volumes locaux montés. \(model.trashInventory?.isPartial == true ? "Seuls les éléments accessibles et inventoriés seront traités. " : "")Cette suppression est définitive.")
        }
    }

    private var inventoryStep: some View {
        Group {
            if model.trashInventoryIsLoading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Inventaire de la Corbeille…").font(.headline)
                    Text("Calcul des éléments appartenant à votre compte sur les volumes montés.").foregroundStyle(.secondary)
                }
            } else if let inventory = model.trashInventory {
                VStack(alignment: .leading, spacing: 16) {
                    Text(inventory.requiresAccess && inventory.items.isEmpty ? "Accès à la corbeille requis" : "Contenu de la corbeille").font(.title.bold())
                    HStack(spacing: 18) {
                        metric("Éléments", value: inventory.items.count.formatted())
                        metric(inventory.isPartial ? "Estimation partielle" : "Taille estimée", value: inventorySize)
                        metric("Erreurs d’accès", value: inventory.issues.count.formatted())
                    }
                    Text("Vider la Corbeille est définitif. Vérifiez son contenu dans le Finder avant de continuer.")
                        .padding(12).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    Text("Corbeilles de votre compte sur les stockages locaux montés.").font(.caption).foregroundStyle(.secondary)
                    if inventory.requiresAccess {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("macOS a refusé l’accès à une partie de la corbeille. Vérifiez StorageScope dans Réglages Système → Confidentialité et sécurité → Accès complet au disque, puis cliquez sur Actualiser. Si l’accès est déjà activé, vérifiez aussi les droits de l’élément dans le Finder. Une relance de StorageScope peut être nécessaire après un changement d’autorisation.")
                            Button("Vérifier l’accès complet au disque", action: PermissionActions.openFullDiskAccess)
                        }.padding(12).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !inventory.items.isEmpty {
                        List(inventory.items) { item in
                            HStack {
                                Label(item.url.lastPathComponent, systemImage: item.isDirectory ? "folder" : "doc").lineLimit(1)
                                Spacer()
                                Text(item.sizeIsComplete ? ByteCountFormatter.storage.string(fromByteCount: item.allocatedBytesUpperBound) : "Taille partielle ou indisponible").foregroundStyle(.secondary)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder.badge.magnifyingglass") }
                                    .help("Afficher dans le Finder").accessibilityLabel("Afficher \(item.url.lastPathComponent) dans le Finder")
                            }.frame(height: 34).help(item.url.path)
                        }.frame(minHeight: 100)
                    } else if inventory.issues.isEmpty && !inventory.wasCancelled {
                        Label("La corbeille est vide", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    if !inventory.issues.isEmpty {
                        DisclosureGroup("Zones non inventoriées") {
                            ForEach(inventory.issues.prefix(20)) { issue in
                                Text("\(issue.path) — \(issue.message)").font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    Spacer()
                    HStack {
                        Button("Ouvrir la Corbeille") {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true))
                        }
                        Spacer()
                        Button(inventory.isPartial ? "Vider les éléments inventoriés…" : "Vider la corbeille…", role: .destructive) { confirming = true }
                            .disabled(inventory.items.isEmpty || inventory.wasCancelled || model.operationsAreBusy || model.trashSummaryIsLoading)
                    }
                }
                .padding(24)
            }
        }
    }

    private var runningStep: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Suppression définitive en cours…").font(.title2.bold())
            Text("Ne fermez pas StorageScope pendant cette opération.").foregroundStyle(.secondary)
        }
    }

    private var resultStep: some View {
        VStack(alignment: .leading, spacing: 17) {
            if let result = model.emptyTrashResult {
                let deleted = result.itemResults.filter { $0.status == .deleted }.count
                let failed = result.itemResults.count - deleted
                let complete = failed == 0 && !result.inventoryWasPartial
                Label(complete ? "Corbeille vidée" : "Vidage partiel", systemImage: complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title.bold()).foregroundStyle(complete ? .green : .orange)
                HStack(spacing: 18) {
                    metric("Supprimés", value: deleted.formatted())
                    metric("Échecs", value: failed.formatted())
                    metric("Gain mesuré", value: result.measuredAvailableBytesGain.map(ByteCountFormatter.storage.string(fromByteCount:)) ?? "Actualisation en cours")
                }
                Text("\(result.inventoryWasPartial ? "Taille des éléments mesurés supprimés" : "Borne haute supprimée") : \(ByteCountFormatter.storage.string(fromByteCount: result.deletedBytesUpperBound)). Le gain mesuré du volume reste la valeur de référence.")
                    .foregroundStyle(.secondary)
                if result.inventoryWasPartial { Text("L’inventaire était partiel. Les zones inaccessibles restent à vérifier dans le Finder.").foregroundStyle(.orange) }
                if failed > 0 {
                    DisclosureGroup("Voir les échecs") {
                        ForEach(result.itemResults.filter { $0.status != .deleted }.prefix(30)) { item in
                            Text("\(item.url.path) — \(item.errorDescription ?? item.status.rawValue)").font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            Spacer()
            HStack { Spacer(); Button("Terminer") { dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(26)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var inventorySize: String {
        guard let inventory = model.trashInventory, inventory.hasMeasuredSize else { return "Taille indisponible" }
        return (inventory.isPartial ? "≈ " : "") + ByteCountFormatter.storage.string(fromByteCount: inventory.totalAllocatedBytesUpperBound)
    }
}
