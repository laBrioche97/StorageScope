import AppKit
import Sparkle
import StorageCore
import SwiftUI

@MainActor
final class SoftwareUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    @Published private(set) var isConfigured = false
    @Published private(set) var waitingForWork = false
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var status = "Mises à jour indisponibles dans cette distribution non signée."
    @Published private(set) var progress: Double = 0
    @Published private(set) var canCancel = false
    private var updater: SPUUpdater?
    private var postponedInstallation: (() -> Void)?
    private var cancellation: (() -> Void)?
    private var installRequested = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var offline = false
    var isBusy = false
    var symbol: String { checking || installing ? "arrow.triangle.2.circlepath" : availableVersion != nil ? "arrow.down.circle.fill" : offline || !isConfigured ? "wifi.slash" : "checkmark.circle" }

    override init() {
        super.init()
        guard !CommandLine.arguments.contains("--verify-interface"), !CommandLine.arguments.contains("--verify-installation"), let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: key)?.count == 32 else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if let version = UserDefaults.standard.string(forKey: "lastUpdateOffer"), version.compare(current, options: .numeric) == .orderedDescending {
            availableVersion = version; status = "Version \(version) · offre de la dernière vérification, à revalider en ligne."
        }
        let instance = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater = instance
        do {
            try instance.start()
            instance.automaticallyDownloadsUpdates = false
            instance.automaticallyChecksForUpdates = false
            isConfigured = true
            if PackagedValidation.updateFeed != nil {
                installRequested = true; checking = true; instance.checkForUpdates()
            } else { check() } // Informational probe at every normal launch; never auto-install.
        } catch { status = "Vérification impossible : \(error.localizedDescription)"; updater = nil }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { PackagedValidation.updateFeed }
    func check() {
        guard isConfigured, !checking, !installing, let updater, updater.canCheckForUpdates else { return }
        checking = true; offline = false; status = "Recherche de mises à jour…"
        updater.checkForUpdateInformation()
    }
    func activate() {
        guard availableVersion != nil else { check(); return }
        guard !isBusy, !checking, !installing, let updater, updater.canCheckForUpdates else { return }
        installRequested = true; checking = true; status = "Revalidation de la mise à jour…"
        updater.checkForUpdates()
    }
    func cancel() {
        cancellation?(); cancellation = nil; canCancel = false; installRequested = false
        installing = false; checking = false; status = "Mise à jour annulée. La version actuelle reste utilisable."
    }
    func activityChanged(_ busy: Bool) {
        isBusy = busy
        if busy, availableVersion != nil, !installing { status = "Mise à jour disponible après l’analyse ou l’opération en cours." }
        if !busy, let resume = postponedInstallation { postponedInstallation = nil; waitingForWork = false; resume() }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !item.isInformationOnlyUpdate else { availableVersion = nil; status = "La nouvelle version ne dispose pas d’un paquet compatible installable automatiquement."; return }
        availableVersion = item.displayVersionString
        UserDefaults.standard.set(item.displayVersionString, forKey: "lastUpdateOffer")
        UserDefaults.standard.set(Date(), forKey: "lastUpdateOfferDate")
        status = "Mettre à jour vers \(item.displayVersionString) et redémarrer"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil; UserDefaults.standard.removeObject(forKey: "lastUpdateOffer")
        status = "Vous disposez de la dernière version compatible publiée."; checking = false; installRequested = false
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        PackagedValidation.recordUpdate("failed:" + String(describing: error))
        LocalDiagnostics.shared.record(action: "mise à jour Mac", error: error)
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.noUpdateError.rawValue) {
            checking = false; installing = false; installRequested = false
            status = "Aucune mise à jour compatible disponible."; return
        }
        var cause = failure
        offline = cause.domain == NSURLErrorDomain
        for _ in 0..<8 {
            guard let nested = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = nested; offline = offline || cause.domain == NSURLErrorDomain
        }
        checking = false; installing = false; installRequested = false
        status = (offline ? "Connexion indisponible" : "Vérification impossible") + (availableVersion.map { " · version \($0) signalée lors de la dernière vérification ; connexion requise pour la revalider." } ?? " · réessayer.")
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { checking = false }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        postponedInstallation = installHandler; waitingForWork = true; return true
    }
    // Sparkle keeps EdDSA validation and replacement. Only the explicit icon click accepts .install.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.cancellation = cancellation; canCancel = true }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        checking = false
        guard installRequested, !isBusy, !appcastItem.isInformationOnlyUpdate else { installRequested = false; reply(.dismiss); return }
        PackagedValidation.recordUpdate("accepted")
        installing = true; progress = 0; reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { checking = false; installRequested = false; acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { PackagedValidation.recordUpdate("failed:" + String(describing: error)); LocalDiagnostics.shared.record(action: "installation de mise à jour", error: error); installing = false; checking = false; installRequested = false; status = "Mise Ã  jour interrompue : \(error.localizedDescription)"; acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { PackagedValidation.recordUpdate("downloading"); self.cancellation = cancellation; canCancel = true; expected = 0; received = 0; status = "Téléchargement de la mise à jour…" }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) { received += length; progress = expected > 0 ? min(1, Double(received) / Double(expected)) : 0; status = "Téléchargement : \(Int(progress * 100)) %" }
    func showDownloadDidStartExtractingUpdate() { PackagedValidation.recordUpdate("validating"); cancellation = nil; canCancel = false; status = "Vérification et préparation du remplacement…" }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        PackagedValidation.recordUpdate("ready")
        if isBusy { waitingForWork = true; postponedInstallation = { reply(.install) } }
        else { reply(.install) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { status = "Installation et redémarrage…" }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { installing = false; installRequested = false; acknowledgement() }
    func dismissUpdateInstallation() { installing = false; checking = false; canCancel = false; cancellation = nil }
    func showUpdateInFocus() { NSApp.activate(ignoringOtherApps: true) }
}
