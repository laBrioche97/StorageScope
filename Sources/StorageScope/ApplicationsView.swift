import AppKit
import StorageCore
import SwiftUI

struct ApplicationsView: View {
    @EnvironmentObject private var model: AppModel

    private var filteredApplications: [InstalledApplication] {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.applications.filter {
            query.isEmpty || $0.displayName.lowercased().contains(query) || ($0.bundleIdentifier?.lowercased().contains(query) == true)
        }.sorted { lhs, rhs in
            if lhs.allocatedBytesUpperBound != rhs.allocatedBytesUpperBound {
                return lhs.allocatedBytesUpperBound > rhs.allocatedBytesUpperBound
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if model.applicationsAreLoading && model.applications.isEmpty {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Recherche des applications…").font(.title2.bold())
                    Text("Lecture de /Applications et ~/Applications sans exécuter les apps.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading) {
                                Text("Applications").font(.largeTitle.bold())
                                Text("\(filteredApplications.count.formatted()) application(s) · désinstallation prudente par identifiant de bundle")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Actualiser", systemImage: "arrow.clockwise") { model.loadApplications() }
                        }
                        Text("Les caches et réglages certains peuvent être sélectionnés. Les données personnelles, groupes partagés et fichiers administrateur restent séparés.")
                            .padding(12).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                            ForEach(filteredApplications) { application in
                                ApplicationCard(application: application)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .task { model.loadApplications() }
    }
}

private struct ApplicationCard: View {
    @EnvironmentObject private var model: AppModel
    let application: InstalledApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.bundleURL.path))
                    .resizable().scaledToFit().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(application.displayName).font(.headline).lineLimit(1)
                    Text(application.bundleIdentifier ?? "Identifiant absent").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    if let version = application.version { Text("Version \(version)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            HStack {
                Text(application.allocatedBytesUpperBound > 0 ? ByteCountFormatter.storage.string(fromByteCount: application.allocatedBytesUpperBound) : "Taille à calculer")
                    .font(.title3.bold()).monospacedDigit()
                Spacer()
                if let reason = application.protectionReason {
                    Label("Protégée", systemImage: "lock.fill").font(.caption.bold()).foregroundStyle(.secondary).help(reason)
                }
            }
            HStack {
                Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([application.bundleURL]) }
                Spacer()
                Button("Désinstaller proprement…", role: .destructive) { model.prepareUninstall(application) }
                    .disabled(application.isProtected)
            }
        }
        .padding(15)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct UninstallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
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
    }

    private func planView(_ plan: UninstallPlan) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.application.bundleURL.path))
                    .resizable().scaledToFit().frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.application.displayName).font(.title.bold())
                    Text(plan.application.bundleIdentifier ?? "Identifiant absent").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if plan.isRunning { Label("L’application est ouverte et devra être quittée normalement.", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                    if let reason = plan.blockingReason { Label(reason, systemImage: "lock.fill").foregroundStyle(.red) }
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    candidateSection(.applicationBundle, title: "Application", explanation: "Le bundle principal est obligatoire et sera déplacé en premier.", plan: plan)
                    candidateSection(.exactSettingsAndCaches, title: "Réglages et caches", explanation: "Chemins prouvés par l’identifiant exact, sélectionnés par défaut.", plan: plan)
                    candidateSection(.applicationData, title: "Données de l’application", explanation: "Peut contenir des documents ou projets personnels : rien n’est présélectionné.", plan: plan)
                    candidateSection(.sharedOrProtected, title: "Partagés ou protégés", explanation: "Affichés pour information, jamais supprimés par StorageScope.", plan: plan)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Jusqu’à \(ByteCountFormatter.storage.string(fromByteCount: selectedBytes(plan))) seront récupérables après vidage de la Corbeille.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(plan.isRunning ? "Quitter puis désinstaller" : "Mettre à la Corbeille", role: .destructive) {
                    model.performUninstall(requestQuitIfRunning: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!plan.canProceed || model.uninstallIsWorking)
            }
            .padding(16)
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
                        Text(ByteCountFormatter.storage.string(fromByteCount: candidate.allocatedBytesUpperBound)).monospacedDigit()
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(5)
        } label: { Text(title).font(.headline) }
    }

    private func selectedBytes(_ plan: UninstallPlan) -> Int64 {
        plan.candidates.filter { $0.group == .applicationBundle || model.uninstallSelectedIDs.contains($0.id) }
            .reduce(0) { $0 + $1.allocatedBytesUpperBound }
    }

    private func uninstallResult(_ result: UninstallResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(result.status == .succeeded ? "Application déplacée" : "Résultat de la désinstallation", systemImage: result.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title.bold()).foregroundStyle(result.status == .succeeded ? .green : .orange)
            Text(result.message ?? "L’application et les éléments sélectionnés ont été traités.")
            Text("\(ByteCountFormatter.storage.string(fromByteCount: result.recoverableBytesUpperBound)) récupérables après vidage de la Corbeille.")
                .font(.title3.bold())
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
