import AppKit
import StorageCore
import SwiftUI

struct EnhancedCleanupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.cleanupIsAnalyzing {
                analysisView
            } else if let report = model.displayedCleanupReport {
                reportView(report)
            } else if model.isScanning {
                analysisWaitingView
            } else {
                ContentUnavailableView {
                    Label("Nettoyage conseillé", systemImage: "sparkles")
                } description: {
                    Text("L’analyse rapide réutilise l’index du volume et ne lit pas le contenu de vos documents.")
                } actions: {
                    Button("Calculer le nettoyage") { model.calculateCleanup() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }

    private var analysisView: some View {
        VStack(spacing: 22) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                Image(systemName: "sparkles")
                    .font(.system(size: 58, weight: .medium))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) * 120))
                    .shadow(color: .accentColor.opacity(0.25), radius: 18)
            }
            Text(model.cleanupProgress?.phase.rawValue ?? "Analyse du nettoyage").font(.largeTitle.bold())
            if let progress = model.cleanupProgress {
                ProgressView(value: progress.fraction).frame(maxWidth: 480)
                Text("\(progress.completedUnits.formatted()) sur \(progress.totalUnits.formatted()) vérifications")
                    .font(.callout).foregroundStyle(.secondary)
                if let path = progress.currentPath {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 620)
                }
            } else {
                ProgressView().progressViewStyle(.linear).frame(maxWidth: 480)
            }
            Button("Annuler") { model.cancelCleanup() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var analysisWaitingView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Indexation du volume…").font(.title2.bold())
            Text("Le calcul du nettoyage démarrera automatiquement à la fin de cette analyse.").foregroundStyle(.secondary)
            Button("Calculer dès que l’index est prêt") { model.calculateCleanup() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reportView(_ report: CleanupReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Nettoyage conseillé").font(.largeTitle.bold())
                        Text("Jusqu’à \(ByteCountFormatter.storage.string(fromByteCount: report.uniquePotentialBytes)) à examiner")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Recalculer", systemImage: "arrow.clockwise") { model.calculateCleanup() }
                        .buttonStyle(.borderedProminent)
                }

                HStack {
                    Label("Analyse rapide", systemImage: "bolt.fill").font(.headline)
                    Spacer()
                    Text(report.generatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if report.permissionErrors > 0 {
                        Label("Couverture partielle", systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    }
                }
                .padding(12).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))

                Text("Aucun élément n’est sélectionné automatiquement. Les tailles sont des bornes hautes APFS et l’espace devient disponible seulement après vidage de la Corbeille.")
                    .font(.callout).foregroundStyle(.secondary)

                if report.suggestions.isEmpty {
                    ContentUnavailableView("Aucun candidat évident", systemImage: "checkmark.circle", description: Text("Les règles prudentes n’ont rien trouvé à recommander."))
                } else {
                    ForEach(report.suggestions) { suggestion in
                        EnhancedCleanupSuggestionCard(suggestion: suggestion)
                    }
                }

                DuplicateAnalysisPanel()
            }
            .padding(24)
        }
    }
}

private struct EnhancedCleanupSuggestionCard: View {
    @EnvironmentObject private var model: AppModel
    let suggestion: CleanupSuggestion
    @State private var expanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title).font(.headline)
                        Text(suggestion.explanation).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("jusqu’à " + ByteCountFormatter.storage.string(fromByteCount: suggestion.potentialBytes)).font(.headline).monospacedDigit()
                        Text("\(suggestion.itemCount.formatted()) élément(s)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(suggestion.confidence.rawValue).font(.caption.bold()).foregroundStyle(confidenceColor)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(confidenceColor.opacity(0.12), in: Capsule())
                    if suggestion.action == .revealOnly { Text("Inspection uniquement").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(expanded ? "Masquer" : "Examiner") { withAnimation(.snappy) { expanded.toggle() } }
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
                            if suggestion.action == .reviewAndTrash {
                                Button("Corbeille", role: .destructive) { model.requestTrash(items: [item]) }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    if suggestion.itemCount > suggestion.items.count {
                        Text("Affichage limité aux \(suggestion.items.count) plus gros éléments.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(5)
        }
    }

    private var confidenceColor: Color {
        switch suggestion.confidence {
        case .high: .green
        case .medium: .orange
        case .reviewOnly: .secondary
        }
    }
}

/// Filled once DuplicateAnalysisService is available; kept separate so the expensive
/// content read can never start as a side effect of the fast cleanup.
private struct DuplicateAnalysisPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "doc.on.doc.fill").font(.title).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Analyse approfondie des doublons").font(.headline)
                    Text("Compare à la demande les fichiers d’au moins 10 Mo par taille, échantillon puis SHA-256. Aucun fichier n’est présélectionné.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Analyser les doublons") { model.startDuplicateAnalysis() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(7)
            DuplicateResultsInlineView()
        }
    }
}

struct DuplicateResultsInlineView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.duplicateIsAnalyzing {
            VStack(alignment: .leading, spacing: 9) {
                Divider()
                HStack {
                    ProgressView().controlSize(.small)
                    Text(phaseTitle).font(.headline)
                    Spacer()
                    Button("Annuler") { model.cancelDuplicateAnalysis() }
                }
                if let progress = model.duplicateProgress {
                    if progress.totalBytesToHash > 0 {
                        ProgressView(value: min(1, Double(progress.bytesHashed) / Double(progress.totalBytesToHash)))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("\(progress.filesScanned.formatted()) fichiers examinés · \(progress.candidateFiles.formatted()) candidats · \(progress.groupsFound.formatted()) groupes")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(progress.currentPath).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.top, 8)
        } else if let error = model.duplicateError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.top, 8)
        } else if let report = model.duplicateReport {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(report.groups.count.formatted()) groupe(s) confirmé(s)").font(.headline)
                        Text("Jusqu’à \(ByteCountFormatter.storage.string(fromByteCount: report.reclaimableBytesUpperBound)) après sélection")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.duplicateSelectedIDs.isEmpty {
                        Button("Mettre la sélection à la Corbeille", role: .destructive) { model.trashSelectedDuplicates() }
                    }
                }
                if report.groups.isEmpty {
                    Label("Aucun doublon confirmé au-dessus du seuil.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                ForEach(report.groups.prefix(30)) { group in
                    DisclosureGroup {
                        ForEach(group.files) { file in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { model.duplicateSelectedIDs.contains(file.id) },
                                    set: { model.setDuplicateSelected(file, in: group, selected: $0) }
                                ))
                                .labelsHidden()
                                VStack(alignment: .leading) {
                                    Text(file.url.lastPathComponent).lineLimit(1)
                                    Text(file.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteCountFormatter.storage.string(fromByteCount: file.allocatedSize)).monospacedDigit()
                                Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            }
                            .padding(.vertical, 2)
                        }
                    } label: {
                        HStack {
                            Text("\(group.files.count) copies de \(ByteCountFormatter.storage.string(fromByteCount: group.logicalSizePerFile))")
                            Spacer()
                            Text("jusqu’à " + ByteCountFormatter.storage.string(fromByteCount: group.reclaimableBytesUpperBound)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var phaseTitle: String {
        switch model.duplicateProgress?.phase {
        case .enumerating: "Recherche des candidats…"
        case .sampleHashing: "Comparaison des échantillons…"
        case .fullHashing: "Vérification SHA-256…"
        case .finalizing: "Finalisation…"
        case nil: "Analyse des doublons…"
        }
    }
}
