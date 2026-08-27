import AppKit
import SwiftUI

enum PermissionActions {
    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Accès complet au disque", systemImage: "lock.shield.fill").font(.title2.bold())
            Text("macOS protège Mail, Messages, certaines bibliothèques, sauvegardes et données d’applications. Sans autorisation, StorageScope continue l’analyse mais signale honnêtement les zones inaccessibles.")
            Text("Dans Réglages Système, ajoutez l’application à Confidentialité et sécurité → Accès complet au disque, activez-la, puis relancez-la.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Ouvrir les réglages") { PermissionActions.openFullDiskAccess() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(28)
    }
}
