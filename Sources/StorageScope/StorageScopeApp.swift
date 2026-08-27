import SwiftUI

@main
struct StorageScopeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_050, minHeight: 680)
                .task { await model.restoreLastScan() }
        }
        .commands {
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
