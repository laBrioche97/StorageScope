import AppKit
import StorageCore
import SwiftUI

struct EmptyTrashView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Corbeille", systemImage: "trash.fill").font(.title2.bold())
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            Group {
                switch model.emptyTrashStep {
                case .inventory: inventoryStep
                case .confirmation: confirmationStep
                case .running: runningStep
                case .result: resultStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        metric("Borne haute", value: ByteCountFormatter.storage.string(fromByteCount: inventory.totalAllocatedBytesUpperBound))
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
                            .disabled(inventory.items.isEmpty)
                    }
                }
                .padding(24)
            }
        }
    }

    private var confirmationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Confirmation définitive").font(.title.bold())
            Text("Cette opération ne peut pas être annulée. Saisissez exactement VIDER pour autoriser la suppression permanente.")
            TextField("VIDER", text: $model.emptyTrashConfirmation)
                .textFieldStyle(.roundedBorder).font(.title3.monospaced()).frame(maxWidth: 300)
            if let inventory = model.trashInventory {
                Text("\(inventory.items.count) élément(s) · jusqu’à \(ByteCountFormatter.storage.string(fromByteCount: inventory.totalAllocatedBytesUpperBound))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Retour") { model.emptyTrashStep = .inventory }
                Spacer()
                Button("Vider définitivement", role: .destructive) { model.emptyTrashPermanently() }
                    .disabled(model.emptyTrashConfirmation != "VIDER")
            }
        }
        .padding(26)
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
