import StorageCore
import SwiftUI

struct EnhancedCategoriesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let report = model.displayedCategoryReport, !report.summaries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        categoryHeader(report)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 14)], spacing: 14) {
                            ForEach(report.summaries.sorted { $0.allocatedBytes > $1.allocatedBytes }) { summary in
                                CategoryCard(summary: summary, total: max(1, report.identifiedAllocatedBytes)) {
                                    model.openCategory(summary.category)
                                }
                            }
                        }
                        if let volume = model.selectedVolume {
                            unidentifiedCard(volume: volume, identified: report.identifiedAllocatedBytes)
                        }
                    }
                    .padding(24)
                }
            } else if model.isScanning {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Classification de tous les fichiers…").font(.title2.bold())
                    Text("La grille se remplit au fil de l’analyse.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Analyse des catégories requise", systemImage: "square.grid.2x2")
                } description: {
                    Text("Lancez une analyse afin de mesurer tous les fichiers accessibles, pas seulement les plus gros.")
                } actions: {
                    Button("Analyser le volume") { model.startScan() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func categoryHeader(_ report: CategoryReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Répartition du stockage").font(.largeTitle.bold())
                    Text("\(ByteCountFormatter.storage.string(fromByteCount: report.identifiedAllocatedBytes)) classés sur l’ensemble des fichiers accessibles")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isScanning {
                    Label("Calcul en cours", systemImage: "chart.bar.fill")
                        .font(.caption.bold()).foregroundStyle(.orange)
                } else if !report.isComplete {
                    Label("À actualiser", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold()).foregroundStyle(.orange)
                } else {
                    Label("Analyse complète", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold()).foregroundStyle(.green)
                }
            }
            Text("« Autres » contient uniquement des fichiers identifiés mais non classés. Les zones protégées, snapshots et blocs non attribuables sont affichés séparément.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func unidentifiedCard(volume: StorageVolume, identified: Int64) -> some View {
        let difference = max(0, volume.used - identified)
        return HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark").font(.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isScanning ? "Pas encore identifié" : "Système, snapshots et zones non analysées").font(.headline)
                Text("Cet écart n’est pas fusionné avec la catégorie Autres.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.storage.string(fromByteCount: difference)).font(.title3.bold()).monospacedDigit()
        }
        .padding(16)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CategoryCard: View {
    let summary: CategorySummary
    let total: Int64
    let action: () -> Void

    private var fraction: Double { Double(summary.allocatedBytes) / Double(max(1, total)) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: icon).font(.title2).foregroundStyle(color)
                    Spacer()
                    Text(fraction.formatted(.percent.precision(.fractionLength(fraction < 0.01 ? 1 : 0))))
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
                Text(summary.category.rawValue).font(.headline)
                Text(ByteCountFormatter.storage.string(fromByteCount: summary.allocatedBytes))
                    .font(.title2.bold()).monospacedDigit()
                Text("\(summary.fileCount.formatted()) fichier(s)").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: fraction).tint(color)
                if let contributor = summary.topContributors.first {
                    Text("Principal : \(contributor.name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .padding(16)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(color.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .help("Ouvrir cette catégorie dans l’Explorateur")
    }

    private var color: Color {
        switch summary.category {
        case .application: .indigo
        case .applicationData: .purple
        case .image: .pink
        case .video: .red
        case .audio: .orange
        case .document: .blue
        case .archive: .brown
        case .development: .mint
        case .virtualMachine: .cyan
        case .backup: .teal
        case .mailAndMessages: .green
        case .cacheAndLogs: .yellow
        case .systemAndLibrary: .gray
        case .other: .secondary
        }
    }

    private var icon: String {
        switch summary.category {
        case .application: "app.fill"
        case .applicationData: "shippingbox.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .document: "doc.fill"
        case .archive: "archivebox.fill"
        case .development: "hammer.fill"
        case .virtualMachine: "cube.box.fill"
        case .backup: "externaldrive.badge.timemachine"
        case .mailAndMessages: "envelope.fill"
        case .cacheAndLogs: "bolt.horizontal.circle.fill"
        case .systemAndLibrary: "gearshape.2.fill"
        case .other: "ellipsis.circle.fill"
        }
    }
}
