import AppKit
import StorageCore
import SwiftUI

struct UninstallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var inventory: InventoryPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if !model.uninstallActionMessage.isEmpty {
                Label(model.uninstallActionMessage, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).padding(14)
            }
            HStack {
                Label("Désinstaller proprement", systemImage: "app.badge.checkmark").font(.title2.bold())
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if model.uninstallIsWorking && model.uninstallPlan == nil {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Recherche des fichiers associés…").font(.title2.bold())
                    Text("Vérification des chemins exacts, conteneurs et réglages.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = model.uninstallResult {
                uninstallResult(result)
            } else if let plan = model.uninstallPlan {
                planView(plan)
            }
        }
        .task(id: model.uninstallResult == nil ? model.uninstallPlan?.generatedAt : nil) { await model.measureUninstallPlan() }
    }

    private func planView(_ plan: UninstallPlan) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.application.bundleURL.path))
                    .resizable().scaledToFit().frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.application.displayName).font(.title.bold()).lineLimit(2)
                    Text(plan.application.bundleIdentifier ?? "Identifiant absent").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text((model.uninstallSizes[plan.application.id] ?? model.installationSize(at: plan.application.bundleURL)).label).monospacedDigit()
                    Text("Sauvegardes conservées par défaut · résidus examinés séparément").font(.caption).foregroundStyle(.secondary)
                    if plan.isRunning { Label("L’application est ouverte et devra être quittée normalement.", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                    if let reason = plan.blockingReason { Label(reason, systemImage: "lock.fill").foregroundStyle(.red) }
                    if plan.application.eligibility == .authorizationRequired {
                        Label("macOS peut vous demander une autorisation. Vos identifiants sont saisis uniquement dans sa fenêtre système.", systemImage: "person.badge.key.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    candidateSection(.applicationBundle, title: "Application", explanation: "Le bundle principal est obligatoire et sera déplacé en premier.", plan: plan)
                    candidateSection(.exactSettingsAndCaches, title: "Réglages et caches", explanation: "Chemins prouvés par l’identifiant exact. Seuls les caches et journaux sont présélectionnés ; les réglages restent conservés.", plan: plan)
                    candidateSection(.applicationData, title: "Données de l’application", explanation: "Peut contenir des documents ou projets personnels : rien n’est présélectionné.", plan: plan)
                    candidateSection(.sharedOrProtected, title: "Partagés ou protégés", explanation: "Affichés pour information, jamais supprimés par StorageScope.", plan: plan)
                }
                .padding(20)
            }
            Divider()
            HStack {
                if model.uninstallIsWorking { ProgressView().controlSize(.small) }
                Text(model.uninstallSelectionSummary(plan))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(plan.isRunning ? "Quitter puis désinstaller" : "Mettre à la Corbeille", role: .destructive) {
                    model.performUninstall(requestQuitIfRunning: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!plan.canProceed || model.uninstallIsWorking)
            }
            .padding(16)
            if case .officialUninstallerRequired = plan.application.eligibility {
                HStack {
                    Text("Ouvrez l’application pour utiliser sa méthode officielle, ou consultez son emplacement.").font(.caption).foregroundStyle(.secondary)
                    Button("Ouvrir l’application") { NSWorkspace.shared.open(plan.application.bundleURL) }
                    Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([plan.application.bundleURL]) }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
    }

    private func candidateSection(_ group: UninstallCandidateGroup, title: String, explanation: String, plan: UninstallPlan) -> some View {
        let candidates = plan.candidates.filter { $0.group == group }
        return GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                if candidates.isEmpty { Text("Aucun élément trouvé").font(.caption).foregroundStyle(.tertiary) }
                ForEach(candidates) { candidate in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { group == .applicationBundle || model.uninstallSelectedIDs.contains(candidate.id) },
                            set: { selected in
                                if selected { model.uninstallSelectedIDs.insert(candidate.id) }
                                else { model.uninstallSelectedIDs.remove(candidate.id) }
                            }
                        ))
                        .labelsHidden()
                        .disabled(group == .applicationBundle || !candidate.isRemovable)
                        Image(systemName: candidate.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(candidate.isDirectory ? .blue : .secondary)
                        VStack(alignment: .leading) {
                            Text(candidate.url.lastPathComponent).lineLimit(1)
                            Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                            Text(candidate.url.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(model.uninstallSizes[candidate.id]?.label ?? (candidate.isDirectory ? "Calcul en cours…" : InstallationSize(bytes: candidate.allocatedBytesUpperBound, state: .measured).label)).monospacedDigit()
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(5)
        } label: { Text(title).font(.headline) }
    }

    private func uninstallResult(_ result: UninstallResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(result.status == .succeeded ? "Application déplacée" : "Résultat de la désinstallation", systemImage: result.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title.bold()).foregroundStyle(result.status == .succeeded ? .green : .orange)
            Text(result.message ?? "L’application et les éléments sélectionnés ont été traités.")
            Text(model.uninstallResultSummary(result))
                .font(.title3.bold())
            if result.status == .authorizationRequired || result.status == .authorizationDenied {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Autorisez uniquement l’accès nécessaire, puis continuez avec la même sélection.").foregroundStyle(.secondary)
                    HStack {
                        Button("Gestion des apps") { PermissionActions.openAppManagement() }
                        Button("Automatisation du Finder") { PermissionActions.openAutomation() }
                    }
                    Button("Autoriser et continuer") { model.performUninstall(allowFinderAuthorization: true) }
                        .buttonStyle(.borderedProminent).disabled(model.uninstallIsWorking || model.operationsAreBusy)
                    if model.operationsAreBusy && !model.uninstallIsWorking { Text("Une autre opération est en cours. Terminez-la ou annulez-la pour continuer.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !result.associatedResults.isEmpty {
                let failures = result.associatedResults.filter { $0.status == .failed }
                Text("\(result.associatedResults.count - failures.count) associé(s) déplacé(s), \(failures.count) échec(s).").foregroundStyle(.secondary)
            }
            Spacer()
            HStack { Spacer(); Button("Terminer") { dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(26)
    }
}
