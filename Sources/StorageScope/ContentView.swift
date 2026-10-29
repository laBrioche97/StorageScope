import AppKit
import StorageCore
import SwiftUI

struct ContentView: View {
    @State private var sidebarVisible = true
    @State private var compactWindow = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var updates: SoftwareUpdates

    private var detailTitle: String {
        let section = model.sidebar?.rawValue ?? "Stockage"
        guard let volume = model.selectedVolume else { return section }
        return "\(section) — \(volume.name)"
    }

    private let sections: [SidebarSection] = [.applications, .overview, .explorer, .categories, .cleanup]

    private var sidebarNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sections) { section in
                Button {
                    let previous = model.sidebar
                    model.sidebar = section
                    // Only a deliberate sidebar entry opens the storage chooser.
                    // Programmatic category/cleanup navigation already has a target.
                    if section == .explorer, previous != .explorer, !model.isPreviewMode { model.enterExplorer() }
                    if compactWindow { sidebarVisible = false }
                } label: {
                    Label(section.rawValue, systemImage: section.icon).font(.system(size: 13, weight: model.sidebar == section ? .semibold : .medium))
                        .lineLimit(1).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(model.sidebar == section ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .animation(MotionTokens.enabled ? .easeOut(duration: MotionTokens.section) : nil, value: model.sidebar == section)
                .accessibilityAddTraits(model.sidebar == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Label("Analyse locale", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.padding(10).frame(width: 220).background(.regularMaterial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Afficher ou masquer la navigation", systemImage: "sidebar.left") { sidebarVisible.toggle() }.labelStyle(.iconOnly)
                BriocheLogo().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                Text(AppIdentity.title).font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(1)
                Button { updates.activate() } label: { Image(systemName: updates.symbol) }
                    .help(updates.status).accessibilityLabel(updates.status)
                    .disabled(updates.checking || updates.installing || (updates.availableVersion != nil && model.operationsAreBusy))
                if updates.installing {
                    ProgressView(value: updates.progress).frame(width: 70)
                    if updates.canCancel { Button("Annuler") { updates.cancel() } }
                }
                Spacer()
                Button { model.prepareEmptyTrash() } label: {
                    Label(model.trashSummaryLabel, systemImage: "trash").lineLimit(1)
                }.labelStyle(.titleAndIcon).controlSize(.small)
                    .help("Corbeille du compte courant sur les stockages locaux · voir la taille et vider")
            }.padding(.horizontal, 16).padding(.vertical, 8)
            HStack(spacing: 0) {
                if sidebarVisible && !compactWindow { sidebarNavigation; Divider() }
                sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .leading) {
                if sidebarVisible && compactWindow { sidebarNavigation.shadow(radius: 8, x: 3) }
            }
        }
        .background(WindowLayoutObserver { compact in
            guard compact != compactWindow else { return }
            compactWindow = compact
            sidebarVisible = !compact
        })
        .task { model.refreshTrashSummary(force: true) }
        .environmentObject(model.inventory)
        .accentColor(AppTheme.accent)
        .background(AppTheme.canvas(colorScheme))
        .buttonStyle(SoftButtonStyle())
        .toolbar { toolbar }
        .navigationTitle(detailTitle)
        .onChange(of: model.sidebar) { _, section in
            guard section == model.sidebar else { return }
            if section != .explorer { model.navigate(to: nil) }
            if section == .applications { model.loadApplications() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshVolumes(); model.refreshTrashSummary() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            model.refreshVolumes()
        }
        .alert("Mettre à la corbeille ?", isPresented: $model.showingTrashConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Mettre à la corbeille", role: .destructive) { model.confirmTrash() }
        } message: {
            Text("\(model.trashConfirmationItems.count) élément(s) · environ \(ByteCountFormatter.storage.string(fromByteCount: model.trashConfirmationBytes)) seront récupérables une fois la Corbeille vidée.")
        }
        .alert("StorageScope", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
        .sheet(isPresented: $model.showingAccessIssues) {
            if let snapshot = model.snapshot {
                AccessIssuesView(snapshot: snapshot)
                    .frame(minWidth: 780, minHeight: 520)
            }
        }
        .sheet(isPresented: $model.showingEmptyTrash) {
            EmptyTrashView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 500)
        }
        .sheet(isPresented: $model.showingUninstall) {
            UninstallView()
                .environmentObject(model)
                .environmentObject(model.inventory)
                .frame(minWidth: 660, minHeight: 560)
        }
    }

    private var sectionContent: some View {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Rechercher dans cette section", text: $model.searchText).textFieldStyle(.roundedBorder)
                    if !model.searchText.isEmpty || model.sizeFilter != .all || model.kindFilter != .all || model.categoryFilter != nil {
                        Button("Effacer les filtres") { model.resetSectionFilters() }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
                Group {
                if model.sidebar == .volumes {
                    VolumesView()
                } else if model.sidebar == .explorer {
                    if model.choosingExplorerStorage { ExplorerStorageChooser() }
                    else {
                        VStack(alignment: .leading) {
                            HStack { Button("Changer de stockage", systemImage: "externaldrive") { model.showExplorerStorages() }.disabled(model.operationsAreBusy); Text(model.storageChoiceMessage).font(.caption).foregroundStyle(.secondary) }.padding(.horizontal)
                            StorageExplorerView()
                        }
                    }
                } else if model.sidebar == .applications {
                    ApplicationsView()
                } else if model.sidebar == .cleanup {
                    EnhancedCleanupView()
                } else if model.sidebar == .categories {
                    EnhancedCategoriesView()
                } else {
                    StorageResultsView()
                }
            }
            }
            .softTransition(model.sidebar?.rawValue ?? "", duration: MotionTokens.section, zoom: false)
    }

    private func openLocalFolder(_ name: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StorageScope/" + name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); NSWorkspace.shared.open(directory) }
        catch { model.alertMessage = error.localizedDescription }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Volume", selection: Binding(
                get: { model.selectedVolumeID },
                set: { model.selectVolume(id: $0) }
            )) {
                ForEach(model.volumes) { Text($0.name).tag($0.id) }
            }
            .frame(width: 170)
            .disabled(model.operationsAreBusy && !model.isScanning)

            Menu("Plus", systemImage: "ellipsis.circle") {
                Button("Rechercher des mises à jour…") { updates.check() }.disabled(model.operationsAreBusy)
                Button("Historique local") { openLocalFolder("History") }
                Button("Ouvrir les diagnostics") { openLocalFolder("Diagnostics") }
                Button("Exporter les diagnostics…") { DiagnosticLifecycle.export() }
                Divider()
                Menu("Autres vues") {
                    ForEach([SidebarSection.largestFiles, .largestFolders, .volumes, .lastScan]) { section in
                        Button(section.rawValue) { model.sidebar = section }
                    }
                }
            }

            if model.isScanning {
                Button("Arrêter", systemImage: "stop.fill") { model.stopScan() }
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Analyser le disque", systemImage: "play.fill") { model.startScan() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

private struct ExplorerStorageChooser: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choisir un stockage").font(.title.bold())
                Text(model.storageChoiceMessage).foregroundStyle(.secondary)
                Button("Actualiser les stockages") { model.refreshVolumes() }
                ForEach(model.volumes.filter(\.isLocal)) { volume in
                    Button { model.openExplorerStorage(id: volume.id) } label: {
                        HStack(spacing: 16) {
                            Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(volume.name).font(.headline)
                                Text(volume.url.path).font(.caption)
                                Text(volume.statisticsAvailable ? "Capacité : \(ByteCountFormatter.storage.string(fromByteCount: volume.capacity)) · \(ByteCountFormatter.storage.string(fromByteCount: volume.available)) libres" : "Capacité et espace libre indisponibles")
                            }
                            Spacer(); Image(systemName: "chevron.right")
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered).disabled(model.operationsAreBusy && !model.isScanning)
                }
            }.padding(20)
        }
    }
}

private struct StorageResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text("1. Analyser  →  2. Choisir  →  3. Vérifier  →  4. Nettoyer")
                .font(.callout).foregroundStyle(.secondary).padding(12)
            if let volume = model.selectedVolume {
                VolumeCard(
                    volume: volume,
                    identified: model.snapshot?.progress.allocatedBytesDiscovered,
                    isScanning: model.isScanning,
                    recoverableTrashBytes: model.recoverableTrashBytes
                )
            }
            if model.sidebar == .overview { CategoryOverview() }
            if model.isScanning { ScanProgressView(status: model.scanStatus) }
            if let snapshot = model.snapshot {
                if snapshot.progress.permissionErrors > 0 {
                    PermissionBanner(snapshot: snapshot) { model.showingAccessIssues = true }
                }
                breadcrumb(snapshot: snapshot)
                filters
                HStack(spacing: 0) {
                    ItemTable(items: model.visibleItems)
                    if let selected = model.selectedItems.first, model.selectedItems.count == 1 {
                        Divider()
                        ItemDetailView(item: selected)
                            .frame(width: 270)
                    }
                }
                selectionBar
            } else if model.isScanning {
                ContentUnavailableView("Préparation de l’index…", systemImage: "externaldrive.badge.timemachine", description: Text("Les premiers résultats apparaîtront après environ 1 000 éléments."))
            } else {
                ContentUnavailableView {
                    Label("Trouvez ce qui prend de la place", systemImage: "internaldrive")
                } description: {
                    Text("Analyse locale du système de fichiers, fondée sur l’espace réellement alloué.")
                } actions: {
                    Button("Analyser le Mac") { model.startScan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder private func breadcrumb(snapshot: ScanSnapshot) -> some View {
        if let current = model.currentDirectory {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button(model.selectedVolume?.name ?? (snapshot.root.lastPathComponent.isEmpty ? "Volume" : snapshot.root.lastPathComponent)) { model.navigate(to: snapshot.root) }
                    let components = pathComponents(from: snapshot.root, to: current)
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        Button(component) {
                            let target = components.prefix(index + 1).reduce(snapshot.root) { $0.appendingPathComponent($1, isDirectory: true) }
                            model.navigate(to: target)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.vertical, 8)
            }
            Divider()
        }
    }

    private func pathComponents(from root: URL, to url: URL) -> [String] {
        let rootParts = root.standardizedFileURL.pathComponents
        let all = url.standardizedFileURL.pathComponents
        return Array(all.dropFirst(min(rootParts.count, all.count)))
    }

    private var filters: some View {
        VStack(alignment: .leading) {
            ResultFilters()
            Picker("Catégorie", selection: $model.categoryFilter) {
                Text("Toutes catégories").tag(ItemCategory?.none)
                ForEach(ItemCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.labelsHidden().frame(width: 180)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var selectionBar: some View {
        if !model.selectedItems.isEmpty {
            HStack {
                Text("\(model.selectedItems.count) élément(s) sélectionné(s) · \(ByteCountFormatter.storage.string(fromByteCount: model.selectedBytes))")
                Spacer()
                Button("Mettre à la corbeille", role: .destructive) { model.requestTrashSelection() }
                    .disabled(model.selectedItems.contains { !$0.isTrashable })
            }
            .padding(10).background(.bar)
        }
    }
}

private struct VolumeCard: View {
    let volume: StorageVolume
    var identified: Int64? = nil
    var isScanning = false
    var recoverableTrashBytes: Int64 = 0
    var ratio: Double { volume.capacity > 0 ? Double(volume.used) / Double(volume.capacity) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(volume.name, systemImage: "internaldrive.fill").font(.title2.bold())
                Spacer()
                Text("\(ByteCountFormatter.storage.string(fromByteCount: volume.used)) utilisés sur \(ByteCountFormatter.storage.string(fromByteCount: volume.capacity))")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: ratio).tint(ratio > 0.9 ? .orange : .accentColor)
            Text("\(ByteCountFormatter.storage.string(fromByteCount: volume.available)) disponibles")
                .font(.caption).foregroundStyle(.secondary)
            if recoverableTrashBytes > 0 {
                Label("\(ByteCountFormatter.storage.string(fromByteCount: recoverableTrashBytes)) récupérables après vidage de la Corbeille", systemImage: "trash")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let identified {
                HStack {
                    Text("Fichiers identifiés : \(ByteCountFormatter.storage.string(fromByteCount: identified))")
                    Spacer()
                    Text("\(isScanning ? "Pas encore identifié" : "Non attribué / système / snapshots") : \(ByteCountFormatter.storage.string(fromByteCount: max(0, volume.used - identified)))")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .padding(16)
    }
}

struct ScanProgressView: View {
    @ObservedObject var status: ScanStatus
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let progress = status.progress
            let elapsed = max(0.1, context.date.timeIntervalSince(progress.startedAt))
            let itemCount = progress.filesScanned + progress.directoriesScanned
            let rate = Double(itemCount) / elapsed
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(status.isFinalizing ? "Finalisation de l’index…" : "Analyse en cours…").font(.headline)
                    Spacer()
                    Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let fraction = status.estimatedFraction {
                    ProgressView(value: fraction)
                    Text("Estimation basée sur la dernière analyse · \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Première analyse : total inconnu, barre d’activité sans pourcentage artificiel")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Text("\(progress.filesScanned.formatted()) fichiers")
                    Text("\(progress.directoriesScanned.formatted()) dossiers")
                    Text(ByteCountFormatter.storage.string(fromByteCount: progress.allocatedBytesDiscovered) + " identifiés")
                    Text("\(Int(rate).formatted()) éléments/s")
                }.font(.caption).foregroundStyle(.secondary)
                Text(progress.currentPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
        }.padding(.horizontal, 18).padding(.bottom, 10)
    }
}

private struct PermissionBanner: View {
    let snapshot: ScanSnapshot
    let showDetails: () -> Void

    private var privacyCount: Int {
        snapshot.issues.lazy.filter { $0.isPermissionError && AccessIssueClassifier.category(for: $0) == .privacy }.count
    }

    var body: some View {
        HStack {
            Image(systemName: privacyCount > 0 ? "lock.trianglebadge.exclamationmark.fill" : "checkmark.shield.fill")
                .foregroundStyle(privacyCount > 0 ? .orange : .secondary)
            if privacyCount > 0 {
                Text("\(privacyCount) zone(s) de données utilisateur restent inaccessibles. Vérifie les détails.")
            } else {
                Text("\(snapshot.progress.permissionErrors) zone(s) protégée(s) par macOS ont été ignorées — cela peut être normal même avec l’accès complet.")
            }
            Spacer()
            Button("Voir les détails", action: showDetails)
            Button("Réglages") { PermissionActions.openFullDiskAccess() }
        }
        .padding(10).background((privacyCount > 0 ? Color.orange : Color.secondary).opacity(0.1))
    }
}

private struct AccessIssuesView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: ScanSnapshot

    private var categories: [(AccessIssueCategory, [ScanIssue])] {
        AccessIssueCategory.allCases.compactMap { category in
            let values = snapshot.issues.filter { AccessIssueClassifier.category(for: $0) == category }
            return values.isEmpty ? nil : (category, values)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Couverture de l’analyse", systemImage: "lock.shield")
                        .font(.title2.bold())
                    Spacer()
                    Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text("\(snapshot.progress.permissionErrors) refus d’accès et \(snapshot.progress.skippedItems) élément(s) ignoré(s). L’accès complet au disque ne contourne ni SIP, ni les permissions Unix, ni les zones réservées à root.")
                    .foregroundStyle(.secondary)
                if snapshot.issues.count >= 500 {
                    Text("La liste est limitée aux 500 premiers exemples.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            List {
                ForEach(categories, id: \.0) { category, issues in
                    Section {
                        ForEach(issues) { issue in
                            AccessIssueRow(issue: issue)
                        }
                    } header: {
                        Text("\(category.rawValue) · \(issues.count)")
                    } footer: {
                        if category == .system {
                            Text("Ces chemins restent généralement inaccessibles sans privilèges root et ne doivent pas être contournés.")
                        } else if category == .privacy {
                            Text("Ces chemins devraient souvent devenir lisibles après activation de l’accès complet et relance de l’application.")
                        }
                    }
                }
            }
        }
    }
}

private struct AccessIssueRow: View {
    let issue: ScanIssue
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: issue.isPermissionError ? "lock.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.isPermissionError ? .orange : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.path).font(.callout.monospaced()).textSelection(.enabled)
                Text(issue.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Copier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.path, forType: .string)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ItemTable: View {
    let items: [FileSystemItem]
    var body: some View {
        NativeFileTable(items: items, mode: .overview)
            .overlay {
                if items.isEmpty { ContentUnavailableView("Aucun élément", systemImage: "magnifyingglass", description: Text("Modifiez la recherche ou les filtres.")) }
            }
    }
}

private struct ItemDetailView: View {
    @EnvironmentObject private var model: AppModel
    let item: FileSystemItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 42)).foregroundStyle(item.isDirectory ? .blue : .secondary)
                Text(item.name).font(.headline).textSelection(.enabled)
                LabeledContent("Sur disque", value: ByteCountFormatter.storage.string(fromByteCount: item.allocatedSize))
                LabeledContent("Taille logique", value: ByteCountFormatter.storage.string(fromByteCount: item.logicalSize))
                LabeledContent("Type", value: item.category.rawValue)
                LabeledContent("Risque", value: item.safety.rawValue)
                Text(item.url.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                Divider()
                Button("Afficher dans le Finder") { model.reveal(item) }.buttonStyle(.borderedProminent)
                Button("Copier le chemin") { model.copyPath(item) }
                Button("Mettre à la corbeille", role: .destructive) { model.requestTrashSelection() }.disabled(!item.isTrashable)
            }.padding(16)
        }
    }
}

private struct VolumesView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330))], spacing: 14) {
                ForEach(model.volumes) { volume in
                    VolumeCard(volume: volume)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectVolume(id: volume.id) }
                        .overlay(alignment: .topTrailing) {
                            if volume.id == model.selectedVolumeID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(26) }
                        }
                }
            }.padding()
        }
    }
}

private struct CleanupSuggestionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let report = model.snapshot?.cleanupReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Nettoyage conseillé").font(.largeTitle.bold())
                                Text("Jusqu’à \(ByteCountFormatter.storage.string(fromByteCount: report.uniquePotentialBytes)) à examiner")
                                    .font(.title3).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if report.permissionErrors > 0 {
                                Label("Couverture partielle", systemImage: "lock.trianglebadge.exclamationmark")
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text("Aucun élément n’est sélectionné ou supprimé automatiquement. Les tailles sont des bornes hautes APFS et l’espace n’est libéré qu’après vidage de la Corbeille.")
                            .padding(12)
                            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                        if report.suggestions.isEmpty {
                            ContentUnavailableView("Aucune suggestion évidente", systemImage: "checkmark.circle", description: Text("Le moteur conservateur n’a trouvé aucun candidat fiable parmi ses règles actuelles."))
                        } else {
                            ForEach(report.suggestions) { suggestion in
                                CleanupSuggestionCard(suggestion: suggestion)
                            }
                        }
                    }
                    .padding(24)
                }
            } else if model.isScanning {
                ContentUnavailableView("Suggestions en préparation", systemImage: "sparkles", description: Text("Elles seront publiées après l’agrégation finale, sans ralentir le scan."))
            } else {
                ContentUnavailableView("Analyse requise", systemImage: "sparkles", description: Text("Lance une nouvelle analyse pour obtenir des suggestions basées sur l’ensemble des fichiers parcourus."))
            }
        }
    }
}

private struct CleanupSuggestionCard: View {
    @EnvironmentObject private var model: AppModel
    let suggestion: CleanupSuggestion
    @State private var expanded = false

    private var confidenceColor: Color {
        switch suggestion.confidence {
        case .high: .green
        case .medium: .orange
        case .reviewOnly: .secondary
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title).font(.headline)
                        Text(suggestion.explanation).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("jusqu’à " + ByteCountFormatter.storage.string(fromByteCount: suggestion.potentialBytes)).font(.headline).monospacedDigit()
                        Text("\(suggestion.itemCount.formatted()) élément(s)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(suggestion.confidence.rawValue)
                        .font(.caption.bold()).foregroundStyle(confidenceColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(confidenceColor.opacity(0.12), in: Capsule())
                    if suggestion.action == .revealOnly {
                        Text("Inspection manuelle").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(expanded ? "Masquer" : "Voir les éléments") { withAnimation { expanded.toggle() } }
                }
                if expanded {
                    Divider()
                    ForEach(suggestion.items) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(item.isDirectory ? .blue : .secondary)
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(1)
                                Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteCountFormatter.storage.string(fromByteCount: item.allocatedSize)).monospacedDigit()
                            Button("Finder") { model.reveal(item) }
                            if item.isDirectory { Button("Explorer") { model.examineCleanupItem(item) } }
                        }
                        .padding(.vertical, 3)
                    }
                    if suggestion.itemCount > suggestion.items.count {
                        Text("Affichage limité aux \(suggestion.items.count) plus gros éléments.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(5)
        }
    }
}

private struct CategoriesView: View {
    @EnvironmentObject private var model: AppModel
    var totals: [(ItemCategory, Int64)] {
        let files = model.snapshot?.topFiles ?? []
        return ItemCategory.allCases.map { category in (category, files.filter { $0.category == category }.reduce(0) { $0 + $1.allocatedSize }) }.sorted { $0.1 > $1.1 }
    }
    var maximum: Int64 { totals.first?.1 ?? 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pourquoi mon disque est plein ?").font(.largeTitle.bold())
            Text("Répartition des fichiers identifiés dans l’index. Les catégories ne remplacent jamais les tailles mesurées sur le système de fichiers.").foregroundStyle(.secondary)
            ForEach(totals, id: \.0) { category, bytes in
                HStack {
                    Text(category.rawValue).frame(width: 150, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.75)).frame(width: max(2, proxy.size.width * CGFloat(Double(bytes) / Double(max(1, maximum)))))
                    }.frame(height: 18)
                    Text(ByteCountFormatter.storage.string(fromByteCount: bytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
                }
            }
            Spacer()
        }.padding(28)
    }
}

extension ByteCountFormatter {
    @MainActor static let storage: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}
