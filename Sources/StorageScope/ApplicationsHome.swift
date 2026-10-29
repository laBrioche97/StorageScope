import AppKit
import StorageCore
import SwiftUI

struct ApplicationsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var inventory: InventoryPresentation
    @State private var rows: [ApplicationRowPresentation] = []
    @State private var selectedID: String?
    @State private var showDetails = false
    @State private var showGames = false

    private var selected: ApplicationRowPresentation? { rows.first { $0.id == selectedID } }
    private var queryKey: String { inventory.revision.uuidString + "|" + model.searchText + "|" + model.sort.rawValue + "|\(model.sizeFilter.rawValue)|\(model.applicationProtectionFilter)" }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Un peu d’espace. Beaucoup de possibilités.").font(.system(size: geometry.size.width < 800 ? 23 : 29, weight: .bold, design: .rounded))
                        Text("\(rows.count) applications · \(model.managedGames.count) jeux reconnus").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if model.applicationsAreLoading { ProgressView().controlSize(.small).accessibilityLabel("Actualisation des applications") }
                    Button { model.loadApplications() } label: { Image(systemName: "arrow.clockwise").font(.title3) }
                        .help("Actualiser les applications et les jeux").accessibilityLabel("Actualiser les applications et les jeux")
                        .disabled(model.applicationsAreLoading)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Picker("État", selection: $model.applicationProtectionFilter) {
                            Text("Toutes les apps").tag(0); Text("Désinstallables").tag(1); Text("Protégées et services").tag(2)
                        }.labelsHidden().frame(width: 190)
                        ResultFilters(showsKind: false)
                    }.padding(.vertical, 2)
                }
                if !model.managedGames.isEmpty {
                    DisclosureGroup(isExpanded: $showGames) {
                        ScrollView { ManagedGamesPanel() }.frame(maxHeight: 210)
                    } label: {
                        Label("Jeux et bibliothèques · \(model.managedGames.count)", systemImage: "gamecontroller.fill").font(.headline)
                    }.padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                }
                HStack(spacing: 0) {
                    ZStack {
                        NativeApplicationsTable(rows: rows, icons: inventory.applicationIcons, selection: $selectedID, model: model)
                        if rows.isEmpty {
                            if model.applicationsAreLoading {
                                VStack(spacing: 14) { ProgressView(); Text("Recherche des applications…").font(.headline); Text("L’inventaire reste disponible hors ligne.").foregroundStyle(.secondary) }
                            } else {
                                ContentUnavailableView("Aucune application à afficher", systemImage: "app.dashed", description: Text(model.applications.isEmpty ? "Actualisez l’inventaire de ce Mac." : "Essayez une autre recherche ou effacez les filtres."))
                            }
                        }
                    }
                    if geometry.size.width >= 1040, let selected {
                        Divider().padding(.vertical, 16)
                        ApplicationInspector(row: selected, icon: inventory.applicationIcons[selected.id]) { model.prepareUninstall(selected.application) }
                            .frame(width: 282).softTransition(selected.id)
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                HStack(spacing: 12) {
                    Label("Documents et sauvegardes conservés par défaut", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let selected {
                        if geometry.size.width < 1040 { Button("Détails", systemImage: "info.circle") { showDetails = true } }
                        Button("Vérifier la désinstallation…") { model.prepareUninstall(selected.application) }
                            .buttonStyle(.borderedProminent).disabled(model.operationsAreBusy)
                    }
                }
            }.padding(24)
            .sheet(isPresented: $showDetails) {
                if let selected {
                    VStack {
                        HStack { Spacer(); Button("Fermer") { showDetails = false }.keyboardShortcut(.cancelAction) }
                        ApplicationInspector(row: selected, icon: inventory.applicationIcons[selected.id]) {
                            showDetails = false
                            Task { @MainActor in await Task.yield(); model.prepareUninstall(selected.application) }
                        }
                    }.padding(20).frame(width: 430, height: 490)
                }
            }
        }
        .task(id: queryKey) {
            if !model.searchText.isEmpty { try? await Task.sleep(for: .milliseconds(120)); guard !Task.isCancelled else { return } }
            let apps = model.sort == .name ? inventory.applicationsByName : model.sort == .smallest ? inventory.applicationsSmallest : inventory.applicationsLargest
            let sizes = inventory.sizes, query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let minimum = model.sizeFilter.rawValue, protection = model.applicationProtectionFilter
            let prepared = await Task.detached(priority: .userInitiated) {
                apps.filter {
                    (minimum == 0 || (sizes[$0.id]?.bytes ?? -1) >= minimum)
                    && (protection == 0 || $0.isProtected == (protection == 2))
                    && (query.isEmpty || ($0.displayName + " " + ($0.bundleIdentifier ?? "")).lowercased().contains(query))
                }.map { ApplicationRowPresentation(application: $0, size: sizes[$0.id] ?? InstallationSize()) }
            }.value
            guard !Task.isCancelled else { return }
            rows = prepared
            if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
        }
        .task { if model.applications.isEmpty && !model.applicationsAreLoading { model.loadApplications() } }
    }
}

private struct ApplicationInspector: View {
    let row: ApplicationRowPresentation
    let icon: NSImage?
    let uninstall: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(nsImage: icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application")!)
                    .resizable().scaledToFit().frame(width: 76, height: 76).accessibilityLabel(row.application.displayName)
                VStack(alignment: .leading, spacing: 7) {
                    Text(row.application.displayName).font(.title2.bold()).textSelection(.enabled)
                    Text(row.size).font(.headline).monospacedDigit()
                    Label(row.permission, systemImage: row.application.isProtected ? "lock.shield" : "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                Text("Vous choisissez ce qui part.").font(.headline)
                Text("L’application et ses caches reconnus sont examinés avant toute action. Vos documents, projets et sauvegardes restent conservés par défaut.").font(.callout).foregroundStyle(.secondary)
                if let explanation = row.application.eligibility.explanation { Text(explanation).font(.callout).foregroundStyle(.secondary) }
                Text(row.application.bundleURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Afficher dans le Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([row.application.bundleURL]) }
                Button("Vérifier la désinstallation…", action: uninstall).buttonStyle(.borderedProminent)
            }.padding(22)
        }
    }
}
