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
    @Published private(set) var status = "Mises à jour non configurées dans cette distribution."
    @Published private(set) var progress: Double = 0
    @Published private(set) var canCancel = false
    @Published private(set) var dismissedVersion: String?
    private var updater: SPUUpdater?
    private var postponedInstallation: (() -> Void)?
    private var cancellation: (() -> Void)?
    private var installRequested = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var offline = false
    private var detectionFailed = false
    private var hasChecked = false
    private var startupProbe: Task<Void, Never>?
    private(set) var checksStarted = 0
    @Published private(set) var isBusy = false
    var showsOffer: Bool { availableVersion != nil && availableVersion != dismissedVersion && !installing }
    var canInstallOffer: Bool { isConfigured && availableVersion != nil && !checking && !installing && !isBusy }
    func dismissOffer() { dismissedVersion = availableVersion }
    var offerDetail: String {
        if isBusy { return "Disponible après l’analyse ou l’opération en cours. Votre analyse enregistrée sera conservée." }
        return status + " · Votre analyse enregistrée sera conservée."
    }
    var symbol: String {
        if checking || installing { return "arrow.triangle.2.circlepath" }
        if availableVersion != nil { return "arrow.down.circle.fill" }
        if offline { return "wifi.slash" }
        if !isConfigured || detectionFailed { return "exclamationmark.circle" }
        return hasChecked ? "checkmark.circle" : "clock"
    }

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
            } else {
                status = availableVersion == nil ? "Préparation de la recherche de mises à jour…" : status
                startupProbe = Task { @MainActor [weak self] in
                    for _ in 0..<50 {
                        guard !Task.isCancelled, let self else { return }
                        if instance.canCheckForUpdates { check(); return }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    self?.detectionFailed = true
                    self?.status = "Vérification impossible pour le moment · réessayer."
                }
            } // Informational probe at every normal launch; never auto-install.
        } catch { PackagedValidation.recordUpdate("failed:configuration:" + String(describing: error)); status = "Vérification impossible : \(error.localizedDescription)"; updater = nil }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { PackagedValidation.updateFeed }
    func check() {
        guard isConfigured, !checking, !installing, let updater, updater.canCheckForUpdates else { return }
        checksStarted += 1; detectionFailed = false
        checking = true; offline = false; status = "Recherche de mises à jour…"
        updater.checkForUpdateInformation()
    }
    func activate() {
        guard availableVersion != nil else { check(); return }
        guard !isBusy, !checking, !installing, let updater, updater.canCheckForUpdates else { return }
        dismissedVersion = nil
        installRequested = true; checking = true; status = "Revalidation de la mise à jour…"
        updater.checkForUpdates()
    }
    func cancel() {
        PackagedValidation.recordUpdate("cancelled")
        cancellation?(); cancellation = nil; canCancel = false; installRequested = false
        installing = false; checking = false; status = "Mise à jour annulée. La version actuelle reste utilisable."
    }
    func activityChanged(_ busy: Bool) {
        isBusy = busy
        if busy, availableVersion != nil, !installing { status = "Mise à jour disponible après l’analyse ou l’opération en cours." }
        if !busy, let availableVersion, !checking, !installing {
            status = offline ? "Version \(availableVersion) · offre conservée, à revalider en ligne." : "Mettre à jour vers \(availableVersion) et redémarrer."
        }
        if !busy, let resume = postponedInstallation { postponedInstallation = nil; waitingForWork = false; resume() }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !item.isInformationOnlyUpdate else { availableVersion = nil; status = "La nouvelle version ne dispose pas d’un paquet compatible installable automatiquement."; return }
        presentOffer(version: item.displayVersionString)
    }
    func presentOffer(version: String) {
        if availableVersion != version { dismissedVersion = nil }
        availableVersion = version
        hasChecked = true; detectionFailed = false
        UserDefaults.standard.set(version, forKey: "lastUpdateOffer")
        UserDefaults.standard.set(Date(), forKey: "lastUpdateOfferDate")
        status = "Mettre à jour vers \(version) et redémarrer"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil; UserDefaults.standard.removeObject(forKey: "lastUpdateOffer")
        hasChecked = true; detectionFailed = false
        status = "Vous disposez de la dernière version compatible publiée."; checking = false; installRequested = false
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.noUpdateError.rawValue) {
            hasChecked = true; detectionFailed = false; availableVersion = nil
            UserDefaults.standard.removeObject(forKey: "lastUpdateOffer")
            checking = false; installing = false; installRequested = false
            status = "Aucune mise à jour compatible disponible."; return
        }
        PackagedValidation.recordUpdate("failed:" + String(describing: error))
        LocalDiagnostics.shared.record(action: "mise à jour Mac", error: error)
        var cause = failure
        detectionFailed = true
        let networkCodes: Set<Int> = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet]
        offline = cause.domain == NSURLErrorDomain && networkCodes.contains(cause.code)
        for _ in 0..<8 {
            guard let nested = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = nested; offline = offline || (cause.domain == NSURLErrorDomain && networkCodes.contains(cause.code))
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
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { PackagedValidation.recordUpdate("failed:" + String(describing: error)); LocalDiagnostics.shared.record(action: "installation de mise à jour", error: error); installing = false; checking = false; installRequested = false; status = "Mise à jour interrompue : \(error.localizedDescription)"; acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { PackagedValidation.recordUpdate("downloading"); self.cancellation = cancellation; canCancel = true; expected = 0; received = 0; status = "Téléchargement de la mise à jour…" }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length; progress = expected > 0 ? min(1, Double(received) / Double(expected)) : 0
        status = "Téléchargement : \(Int(progress * 100)) %"
        if PackagedValidation.updateFeed != nil, ProcessInfo.processInfo.environment["STORAGESCOPE_UPDATE_VALIDATION_CANCEL"] == "1", received >= 65_536 { cancel() }
    }
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
