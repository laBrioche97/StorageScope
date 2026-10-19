import AppKit
import Sparkle
import SwiftUI

@MainActor
final class SoftwareUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var isConfigured = false
    @Published private(set) var waitingForWork = false
    private var controller: SPUStandardUpdaterController?
    private var postponedInstallation: (() -> Void)?
    var isBusy = false

    override init() {
        super.init()
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller?.updater.start()
            controller?.updater.automaticallyDownloadsUpdates = false
            controller?.updater.updateCheckInterval = 86_400
            isConfigured = true
        } catch {
            // Updates never prevent the local application from launching.
            controller = nil
        }
    }

    func check() {
        guard !isBusy else {
            let alert = NSAlert()
            alert.messageText = "Une opération est en cours"
            alert.informativeText = "Terminez le nettoyage ou l’analyse avant de rechercher une mise à jour."
            alert.runModal()
            return
        }
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Version de développement"
            alert.informativeText = "Les mises à jour seront disponibles dans la distribution signée. Toutes les fonctions locales restent accessibles hors ligne."
            alert.runModal()
            return
        }
        controller?.checkForUpdates(nil)
    }

    func activityChanged(_ busy: Bool) {
        isBusy = busy
        if !busy, let resume = postponedInstallation {
            postponedInstallation = nil
            waitingForWork = false
            resume()
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        postponedInstallation = installHandler
        waitingForWork = true
        return true
    }
}
