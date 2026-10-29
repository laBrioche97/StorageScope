import AppKit
import StorageCore
import SwiftUI

enum AppIdentity {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static var title: String { "StorageScope · v" + version }
}

extension ItemCategory {
    var symbol: String {
        switch self {
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
    var tint: Color {
        switch self {
        case .application: .purple
        case .applicationData: .indigo
        case .image: .pink
        case .video: .orange
        case .audio: .red
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
}

@MainActor enum BriocheBrand {
    static let url = EpicGuideResources.bundle.url(forResource: "logo-brioche", withExtension: "png", subdirectory: "Branding")
    static let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "app", accessibilityDescription: "StorageScope")!
}

struct BriocheLogo: View {
    var body: some View {
        Image(nsImage: BriocheBrand.image).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
            .accessibilityLabel("Logo La Brioche")
    }
}

struct BriocheLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raised = false
    let message: String
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            BriocheLogo()
                .frame(width: 82, height: 82).clipShape(RoundedRectangle(cornerRadius: 16))
                .offset(y: raised && !reduceMotion ? -7 : 0)
                .opacity(raised || reduceMotion ? 1 : 0.6)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: raised)
                .accessibilityHidden(true)
            Text(message).multilineTextAlignment(.center).font(.headline)
            Button("Annuler le chargement", action: cancel)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background).onAppear { raised = true }
    }
}

struct CategoryOverview: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let report = model.displayedCategoryReport {
            HStack(spacing: 20) {
                ZStack {
                    Canvas { context, size in
                        let total = Double(max(1, report.identifiedAllocatedBytes))
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        var angle = -90.0
                        for summary in report.summaries where summary.allocatedBytes > 0 {
                            let end = angle + Double(summary.allocatedBytes) / total * 360
                            var path = Path(); path.addArc(center: center, radius: min(size.width, size.height) / 2 - 10, startAngle: .degrees(angle), endAngle: .degrees(end), clockwise: false)
                            context.stroke(path, with: .color(summary.category.tint), style: StrokeStyle(lineWidth: 13, lineCap: .butt))
                            angle = end
                        }
                    }.accessibilityHidden(true)
                    VStack(spacing: 3) {
                        Text(ByteCountFormatter.storage.string(fromByteCount: report.identifiedAllocatedBytes)).font(.headline).monospacedDigit()
                        Text(report.isComplete ? "identifiés" : "analyse partielle").font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(width: 118, height: 118).accessibilityElement(children: .combine)
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(report.summaries.sorted { $0.allocatedBytes > $1.allocatedBytes }) { summary in
                        Button { model.openCategory(summary.category) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(summary.category.rawValue, systemImage: summary.category.symbol).foregroundStyle(summary.category.tint)
                                Text(ByteCountFormatter.storage.string(fromByteCount: summary.allocatedBytes)).font(.headline).foregroundStyle(.primary)
                                Text("\(summary.fileCount.formatted()) fichiers").font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 155, alignment: .leading).padding(14)
                                .background(summary.category.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(summary.category.tint.opacity(0.14)))
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 6)
                }
            }.padding(.horizontal, 20).padding(.bottom, 10).frame(maxHeight: 142)
        }
    }
}
