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
            Text("\(model.trashInventory?.items.count ?? 0) élément(s) · environ \(ByteCountFormatter.storage.string(fromByteCount: model.trashInventory?.totalAllocatedBytesUpperBound ?? 0)). Corbeilles de votre compte sur les volumes locaux montés. Cette suppression est définitive.")
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
                    Text("Première confirmation").font(.title.bold())
                    HStack(spacing: 18) {
                        metric("Éléments", value: inventory.items.count.formatted())
                        metric(inventory.issues.isEmpty && !inventory.wasCancelled ? "Taille estimée" : "Estimation partielle", value: ByteCountFormatter.storage.string(fromByteCount: inventory.totalAllocatedBytesUpperBound))
                        metric("Erreurs d’accès", value: inventory.issues.count.formatted())
                    }
                    Text("Vider la Corbeille est définitif. Vérifiez son contenu dans le Finder avant de continuer.")
                        .padding(12).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
                            if let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Spacer()
                        Button("Continuer…", role: .destructive) { model.emptyTrashStep = .confirmation }
                            .disabled(inventory.items.isEmpty || model.operationsAreBusy)
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
                Label(failed == 0 ? "Corbeille vidée" : "Vidage partiel", systemImage: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title.bold()).foregroundStyle(failed == 0 ? .green : .orange)
                HStack(spacing: 18) {
                    metric("Supprimés", value: deleted.formatted())
                    metric("Échecs", value: failed.formatted())
                    metric("Gain mesuré", value: result.measuredAvailableBytesGain.map(ByteCountFormatter.storage.string(fromByteCount:)) ?? "Actualisation en cours")
                }
                Text("Borne haute supprimée : \(ByteCountFormatter.storage.string(fromByteCount: result.deletedBytesUpperBound)). Le gain mesuré du volume reste la valeur de référence.")
                    .foregroundStyle(.secondary)
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
}
