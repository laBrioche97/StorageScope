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
                    if CommandLine.arguments.contains("--verify-explorer-trash") {
                        do { try await ExplorerTrashValidation.run(model: model); exit(0) }
                        catch { print("Explorer trash validation failed: \(error)"); exit(1) }
                    } else if CommandLine.arguments.contains("--verify-application-removal") {
                        do { try await ApplicationRemovalValidation.run(); exit(0) }
                        catch { print("Application removal validation failed: \(error)"); exit(1) }
                    } else if CommandLine.arguments.contains("--verify-installation") {
                        do { try PackagedValidation.run(); exit(0) }
                        catch { print("Packaged installation validation failed: \(error)"); exit(1) }
                    } else if model.isPreviewMode {
                        do { try await NativeInterfaceValidation.run(); exit(0) }
                        catch { print("Native interface validation failed: \(error)"); exit(1) }
                    } else {
                        await model.restoreLastScan()
                        if CommandLine.arguments.contains("--verify-live-interface") {
                            do { try await NativeLiveInterfaceValidation.run(model: model, updates: updates); exit(0) }
                            catch { print("Live interface validation failed: \(error)"); exit(1) }
                        }
                    }
                }
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
                .frame(width: 600, height: 380)
                .environmentObject(model)
        }
    }
}
