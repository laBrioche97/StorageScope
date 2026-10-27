import SwiftUI

@main
struct StorageScopeApp: App {
    @NSApplicationDelegateAdaptor(DiagnosticLifecycle.self) private var lifecycle
    @StateObject private var model = AppModel()
    @StateObject private var updates = SoftwareUpdates()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .frame(minWidth: 740, minHeight: 560)
                .onChange(of: model.localOperationsAreBusy) { _, busy in updates.activityChanged(busy) }
                .onChange(of: updates.installing) { _, busy in model.updateIsWorking = busy }
                .task {
                    PackagedValidation.recordUpdate("application-started-v" + AppIdentity.version)
                    if CommandLine.arguments.contains("--verify-installation") {
                        do { try PackagedValidation.run(); exit(0) }
                        catch { print("Packaged installation validation failed: \(error)"); exit(1) }
                    } else if model.isPreviewMode {
                        do { try await NativeInterfaceValidation.run(); exit(0) }
                        catch { print("Native interface validation failed: \(error)"); exit(1) }
                    } else { await model.restoreLastScan() }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher des mises Ã  jourâ€¦") { updates.check() }
                    .disabled(model.operationsAreBusy)
            }
            CommandGroup(after: .newItem) {
                Button("Nouvelle analyse") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
            }
            CommandGroup(after: .textEditing) {
                Button("Mettre la sÃ©lection Ã  la corbeille") { model.requestTrashSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedItems.isEmpty)
                Button("AperÃ§u Quick Look") { model.quickLookSelection() }
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
