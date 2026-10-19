import SwiftUI

@main
struct StorageScopeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = SoftwareUpdates()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .frame(minWidth: 780, minHeight: 560)
                .onChange(of: model.operationsAreBusy) { _, busy in updates.activityChanged(busy) }
                .task { await model.restoreLastScan() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher des mises à jour…") { updates.check() }
                    .disabled(model.operationsAreBusy)
            }
            CommandGroup(after: .newItem) {
                Button("Nouvelle analyse") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
            }
            CommandGroup(after: .textEditing) {
                Button("Mettre la sélection à la corbeille") { model.requestTrashSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedItems.isEmpty)
                Button("Aperçu Quick Look") { model.quickLookSelection() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model.selectedItems.count != 1)
            }
        }
        Settings {
            PermissionView()
                .frame(width: 540, height: 320)
                .environmentObject(model)
        }
    }
}
