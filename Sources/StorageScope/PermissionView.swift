import AppKit
import SwiftUI

enum PermissionActions {
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            if !NSWorkspace.shared.open(url), let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(fallback) }
        }
    }
    static func openAppManagement() { open("Privacy_AppBundles") }
    static func openAutomation() { open("Privacy_Automation") }
    static func openFullDiskAccess() {
        open("Privacy_AllFiles")
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Vos autorisations", systemImage: "lock.shield.fill").font(.title2.bold())
            Text("Vous gardez le contrôle. Les autorisations sont demandées pendant l’action concernée ; le reste de StorageScope continue à fonctionner.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                permission("Gestion des apps", detail: "Permettre le déplacement des applications sélectionnées.", action: PermissionActions.openAppManagement)
                permission("Automatisation du Finder", detail: "Recours au Finder après un refus de permissions. Aucun accès demandé au démarrage.", action: PermissionActions.openAutomation)
                permission("Accès complet au disque", detail: "Compléter une analyse lorsque macOS masque certaines bibliothèques. Cet accès ne remplace pas une autorisation administrateur.", action: PermissionActions.openFullDiskAccess)
            }
        }.padding(28)
    }
    private func permission(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Button("Réglages", action: action)
        }
    }
}
