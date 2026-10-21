import AppKit
import StorageCore
import SwiftUI

enum EpicGuideResources {
    static let bundle: Bundle = {
        // Packaged apps keep SwiftPM resources inside Contents/Resources. The
        // generated accessor otherwise only checks the executable's bundle root.
        if let url = Bundle.main.url(forResource: "StorageScope_StorageScope", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}

@MainActor
final class EpicGuideController: NSWindowController, NSWindowDelegate, ObservableObject {
    @Published var status = "Prêt · ouvrez Epic, puis suivez les trois étapes."
    @Published var started = false
    @Published var finished = false
    @Published var verifying = false
    let game: ManagedGame
    private let model: AppModel
    private let adapter = LocalGameLibraryAdapter()
    private var monitoring: Task<Void, Never>?
    init(game: ManagedGame, model: AppModel) {
        self.game = game; self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Désinstaller avec Epic · \(game.name)"; window.minSize = NSSize(width: 460, height: 420)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: EpicGuideView(guide: self))
    }
    required init?(coder: NSCoder) { nil }
    func openEpic() {
        guard !started, !finished, !model.operationsAreBusy else { return }
        started = true; model.gameUninstallIsWorking = true
        monitoring = Task { [weak self] in
            guard let self else { return }
            defer { model.gameUninstallIsWorking = false }
            if let reason = await adapter.unavailabilityReason(game) { complete(reason); return }
            do { try OperationJournal.append(operation: "désinstallation Epic", path: game.installURL.path, status: "préparation") }
            catch { complete("Historique inaccessible. Aucun launcher lancé."); return }
            guard !Task.isCancelled, await adapter.execute(game) else { complete("Epic n’a pas pu être ouvert. Aucun fichier supprimé."); return }
            status = "Intervention dans Epic · vérification locale en cours…"
            for _ in 0..<150 {
                if Task.isCancelled || finished { return }
                if await adapter.verify(game) { confirm(); return }
                try? await Task.sleep(for: .seconds(2))
            }
            complete("Résultat non confirmé. Terminez les étapes dans Epic puis actualisez l’inventaire.")
        }
    }
    func verifyNow() {
        guard !verifying, !finished else { return }
        verifying = true
        Task {
            defer { verifying = false }
            if await adapter.verify(game) { confirm(); monitoring?.cancel() }
            else { status = "Installation encore enregistrée ou résultat non confirmé. Terminez les étapes dans Epic, puis réessayez." }
        }
    }
    private func confirm() {
        guard !finished else { return }
        try? OperationJournal.append(operation: "désinstallation Epic", path: game.installURL.path, status: "confirmée")
        complete("Désinstallation confirmée localement. Les sauvegardes et composants partagés sont conservés.")
        model.refreshVolumes(); model.loadApplications()
    }
    private func complete(_ message: String) {
        guard !finished else { return }
        status = message; finished = true
    }
    func stop() {
        guard !finished else { return }
        monitoring?.cancel()
        complete("Suivi arrêté. Une désinstallation déjà acceptée dans Epic peut continuer. Aucun fichier supprimé par StorageScope.")
        try? OperationJournal.append(operation: "désinstallation Epic", path: game.installURL.path, status: "suivi annulé")
    }
    func windowWillClose(_ notification: Notification) { stop(); window?.contentView = nil }
}

struct EpicGuideView: View {
    @ObservedObject var guide: EpicGuideController
    @State private var modern = false
    @State private var enlarged: String?
    init(guide: EpicGuideController, modern: Bool = false) { self.guide = guide; _modern = State(initialValue: modern) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(guide.game.name).font(.title.bold())
            Text("Confirmez la désinstallation dans Epic. Cette aide reste ouverte pendant l’utilisation du launcher.").foregroundStyle(.secondary)
            Picker("Présentation d’Epic", selection: $modern) { Text("Interface classique").tag(false); Text("Nouvelle interface").tag(true) }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    step(1, "Bibliothèque", modern ? "Cliquez sur Library / Bibliothèque dans la barre supérieure." : "Cliquez sur Library / Bibliothèque dans la colonne gauche.", asset: modern ? "new-library" : "classic-library", rect: modern ? CGRect(x: 0.25, y: 0.095, width: 0.06, height: 0.04) : CGRect(x: 0.005, y: 0.13, width: 0.15, height: 0.065))
                    step(2, "Menu ⋯ du jeu", "Retrouvez votre jeu et ouvrez son menu à trois points. Dans la nouvelle interface, ouvrez d’abord sa fiche.", asset: modern ? "new-game" : "classic-menu", rect: modern ? CGRect(x: 0.60, y: 0.195, width: 0.10, height: 0.08) : CGRect(x: 0.025, y: 0.75, width: 0.91, height: 0.16))
                    step(3, "Désinstaller et confirmer", "Choisissez Uninstall / Désinstaller, puis confirmez dans Epic. Exemple du menu classique ; le libellé est également Désinstaller dans la nouvelle interface.", asset: "classic-menu", rect: CGRect(x: 0.025, y: 0.75, width: 0.91, height: 0.16))
                }
            }
            Text(guide.status).textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
            HStack {
                Button("Ouvrir Epic") { guide.openEpic() }.disabled(guide.started || guide.finished)
                Button("Vérifier maintenant") { guide.verifyNow() }.disabled(guide.verifying || guide.finished)
                Button("Arrêter le suivi") { guide.stop() }.disabled(guide.finished)
            }
            Text("Fermer ou arrêter le suivi ne supprime aucun fichier et n’annule pas une désinstallation acceptée dans Epic. Les sauvegardes restent conservées par StorageScope.").font(.caption).foregroundStyle(.secondary)
        }.padding(18)
        .sheet(isPresented: Binding(get: { enlarged != nil }, set: { if !$0 { enlarged = nil } })) {
            VStack {
                if let enlarged { ScrollView([.horizontal, .vertical]) { Image(enlarged, bundle: EpicGuideResources.bundle) } }
                Button("Fermer l’agrandissement") { enlarged = nil }.keyboardShortcut(.cancelAction)
            }.padding().frame(minWidth: 600, minHeight: 420)
        }
    }
    private func step(_ number: Int, _ title: String, _ caption: String, asset: String, rect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number). \(title)").font(.title3.bold()); Text(caption)
            Button { enlarged = "EpicGuide/\(asset).png" } label: {
                GuideScreenshot(asset: asset, highlight: rect)
            }.buttonStyle(.plain).accessibilityLabel("Étape \(number) : \(title). \(caption) Agrandir la capture officielle.")
        }
    }
}

private struct GuideScreenshot: View {
    let asset: String
    let highlight: CGRect
    var body: some View {
        if let url = EpicGuideResources.bundle.url(forResource: asset, withExtension: "png", subdirectory: "EpicGuide"),
           let image = NSImage(contentsOf: url), let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let crop = asset == "classic-library" ? CGRect(x: 0, y: 95, width: 700, height: 600)
                : asset == "new-library" ? CGRect(x: 300, y: 250, width: 1250, height: 1000)
                : asset == "new-game" ? CGRect(x: 330, y: 290, width: 630, height: 830)
                : CGRect(x: 0, y: 0, width: source.width, height: source.height)
            if let cropped = source.cropping(to: crop) {
                Image(decorative: cropped, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .overlay { GeometryReader { proxy in
                        Rectangle().stroke(.pink, lineWidth: 3)
                            .frame(width: proxy.size.width * highlight.width * Double(source.width) / crop.width, height: proxy.size.height * highlight.height * Double(source.height) / crop.height)
                            .position(x: proxy.size.width * (highlight.midX * Double(source.width) - crop.minX) / crop.width, y: proxy.size.height * (highlight.midY * Double(source.height) - crop.minY) / crop.height)
                    } }.frame(maxHeight: 260)
            }
        }
    }
}
