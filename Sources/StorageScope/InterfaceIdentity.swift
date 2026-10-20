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

struct BriocheMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.16, y: h * 0.82))
        path.addCurve(to: CGPoint(x: w * 0.17, y: h * 0.49), control1: CGPoint(x: 0, y: h * 0.74), control2: CGPoint(x: 0, y: h * 0.49))
        path.addCurve(to: CGPoint(x: w * 0.43, y: h * 0.29), control1: CGPoint(x: w * 0.15, y: h * 0.27), control2: CGPoint(x: w * 0.30, y: h * 0.23))
        path.addCurve(to: CGPoint(x: w * 0.80, y: h * 0.40), control1: CGPoint(x: w * 0.50, y: h * 0.02), control2: CGPoint(x: w * 0.88, y: h * 0.08))
        path.addLine(to: CGPoint(x: w * 0.30, y: h * 0.86))
        path.addQuadCurve(to: CGPoint(x: w * 0.16, y: h * 0.82), control: CGPoint(x: w * 0.23, y: h * 0.91))
        return path
    }
}

struct BriocheLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raised = false
    let message: String
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            BriocheMark().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: 76, height: 76).offset(y: raised && !reduceMotion ? -7 : 0)
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
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(report.summaries.sorted { $0.allocatedBytes > $1.allocatedBytes }) { summary in
                        Button { model.openCategory(summary.category) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(summary.category.rawValue, systemImage: summary.category.symbol).foregroundStyle(summary.category.tint)
                                Text(ByteCountFormatter.storage.string(fromByteCount: summary.allocatedBytes)).font(.headline).foregroundStyle(.primary)
                            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }.padding(12)
            }.frame(maxHeight: 100)
        }
    }
}
