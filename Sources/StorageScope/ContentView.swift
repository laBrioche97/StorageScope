import AppKit
import StorageCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    private var detailTitle: String {
        let section = model.sidebar?.rawValue ?? "Stockage"
        guard let volume = model.selectedVolume else { return section }
        return "\(section) — \(volume.name)"
    }

    private var sidebarSelection: Binding<SidebarSection?> {
        Binding(
            get: { model.sidebar },
            set: { selection in
                guard selection != model.sidebar else { return }
                // macOS 27 can invoke a List selection setter from inside SwiftUI's
                // current render transaction. Publish on the next main-loop turn.
                DispatchQueue.main.async {
                    guard model.sidebar != selection else { return }
                    model.sidebar = selection
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: sidebarSelection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Stockage")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                if model.sidebar == .volumes {
                    VolumesView()
                } else if model.sidebar == .explorer {
                    StorageExplorerView()
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
            .navigationTitle(detailTitle)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Nom, extension ou chemin")
        .toolbar { toolbar }
        .onChange(of: model.sidebar) { _, section in
            if section == .explorer, model.explorerCategoryContext == nil { model.loadExplorerRoot() }
            else { model.navigate(to: nil) }
            if section == .applications { model.loadApplications() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshVolumes() }
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
                .frame(minWidth: 760, minHeight: 620)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Volume", selection: Binding(
                get: { model.selectedVolumeID },
                set: { model.selectVolume(id: $0) }
            )) {
                ForEach(model.volumes) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 190)

            Button("Actualiser les volumes", systemImage: "arrow.clockwise") { model.refreshVolumes() }
                .help("Actualiser l’espace disponible et les volumes montés")

            Button("Corbeille", systemImage: "trash") { model.prepareEmptyTrash() }
                .help("Inventorier ou vider définitivement la Corbeille")

            if model.isScanning {
                Button("Arrêter", systemImage: "stop.fill") { model.stopScan() }
            } else {
                Button("Analyser", systemImage: "play.fill") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

private struct StorageResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let volume = model.selectedVolume {
                VolumeCard(
                    volume: volume,
                    identified: model.snapshot?.progress.allocatedBytesDiscovered,
                    isScanning: model.isScanning,
                    recoverableTrashBytes: model.recoverableTrashBytes
                )
            }
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
        HStack {
            Picker("Taille", selection: $model.sizeFilter) {
                ForEach(SizeFilter.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 105)
            Picker("Catégorie", selection: $model.categoryFilter) {
                Text("Toutes catégories").tag(ItemCategory?.none)
                ForEach(ItemCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.labelsHidden().frame(width: 180)
            Spacer()
            Picker("Trier par", selection: $model.sort) {
                ForEach(ItemSort.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width: 150)
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

private struct ScanProgressView: View {
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
    @EnvironmentObject private var model: AppModel
    let items: [FileSystemItem]

    var body: some View {
        Table(items, selection: $model.selectedIDs) {
            TableColumn("Nom") { item in
                HStack {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(item.isDirectory ? .blue : .secondary)
                    Text(item.name).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.activate(item) }
                .contextMenu { contextMenu(item) }
            }.width(min: 170, ideal: 250)
            TableColumn("Sur disque") { Text(ByteCountFormatter.storage.string(fromByteCount: $0.allocatedSize)).monospacedDigit() }.width(100)
            TableColumn("Logique") { item in
                Text(ByteCountFormatter.storage.string(fromByteCount: item.logicalSize)).foregroundStyle(item.logicalSize != item.allocatedSize ? .primary : .secondary).monospacedDigit()
            }.width(90)
            TableColumn("Type") { Text($0.category.rawValue) }.width(110)
            TableColumn("Emplacement") { Text($0.parentPath).lineLimit(1).truncationMode(.middle) }.width(min: 150, ideal: 260)
            TableColumn("Modification") { Text($0.modificationDate?.formatted(date: .numeric, time: .omitted) ?? "—") }.width(95)
        }
        .overlay {
            if items.isEmpty { ContentUnavailableView("Aucun élément", systemImage: "magnifyingglass", description: Text("Modifiez la recherche ou les filtres.")) }
        }
    }

    @ViewBuilder private func contextMenu(_ item: FileSystemItem) -> some View {
        if item.isDirectory { Button("Explorer") { model.activate(item) } }
        if item.isPackage && item.fileExtension == "app" { Button("Désinstaller proprement…") { model.prepareUninstall(item: item) } }
        Button("Afficher dans le Finder") { model.reveal(item) }
        Button("Ouvrir") { model.open(item) }
        Divider()
        Button("Copier le chemin") { model.copyPath(item) }
        Button("Copier le nom") { model.copyName(item) }
        Divider()
        if item.fileExtension != "app" {
            Button("Mettre à la corbeille", role: .destructive) {
                model.selectedIDs = [item.id]
                model.requestTrashSelection()
            }.disabled(!item.isTrashable)
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
