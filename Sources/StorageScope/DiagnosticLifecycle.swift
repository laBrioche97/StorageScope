import AppKit
import StorageCore

@MainActor
final class DiagnosticLifecycle: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--verify-interface"), !CommandLine.arguments.contains("--verify-installation"),
              !CommandLine.arguments.contains("--verify-live-interface"),
              ProcessInfo.processInfo.environment["STORAGESCOPE_ISOLATED_VALIDATION"] != "1" else { return }
        let interrupted = LocalDiagnostics.shared.begin(version: AppIdentity.version)
        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? ""
            let layoutReason = reason.lowercased().contains("constraint") || reason.contains("NSWindow")
                ? reason.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                : "Détails complémentaires dans le rapport système macOS."
            LocalDiagnostics.shared.record(action: "exception non interceptée", detail: exception.name.rawValue + " · " + layoutReason + "\n" + exception.callStackSymbols.joined(separator: "\n"))
        }
        if interrupted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let alert = NSAlert()
                alert.messageText = "StorageScope s’est arrêté de façon inattendue"
                alert.informativeText = "Les diagnostics restent sur ce Mac. Vous pouvez les consulter ou les exporter depuis le menu Plus. Aucun rapport n’est envoyé automatiquement."
                alert.addButton(withTitle: "Continuer")
                alert.addButton(withTitle: "Ouvrir les diagnostics")
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(LocalDiagnostics.shared.directory) }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { LocalDiagnostics.shared.finish() }
    static func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "StorageScope-diagnostics.log"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try LocalDiagnostics.shared.export(to: destination) }
        catch { NSAlert(error: error).runModal() }
    }
}
