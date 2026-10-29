import AppKit
import CoreServices
import Darwin
import Foundation

public struct ApplicationBundleRemovalRequest: Sendable {
    public let url: URL
    public let bundleIdentifier: String
    public let identity: FileIdentity
    public init(url: URL, bundleIdentifier: String, identity: FileIdentity) {
        self.url = url; self.bundleIdentifier = bundleIdentifier; self.identity = identity
    }
}

public enum ApplicationBundleRemovalStatus: Equatable, Sendable {
    case trashed, authorizationRequired, authorizationDenied, cancelled, notConfirmed, failed
}

public struct ApplicationBundleRemovalOutcome: Sendable {
    public let status: ApplicationBundleRemovalStatus
    public let resultingURL: URL?
    public let message: String?
    public init(_ status: ApplicationBundleRemovalStatus, resultingURL: URL? = nil, message: String? = nil) {
        self.status = status; self.resultingURL = resultingURL; self.message = message
    }
}

public protocol ApplicationBundleRemoving: Sendable {
    func remove(_ request: ApplicationBundleRemovalRequest, allowFinderAuthorization: Bool) async -> ApplicationBundleRemovalOutcome
}

/// An exception for ONE reviewed application bundle. Ordinary file deletion never
/// gains privileges, and associated data is handled separately after verified success.
public actor SystemApplicationBundleRemover: ApplicationBundleRemoving {
    public init() {}

    /// Explicit continuation also covers an empty system reply after permissions
    /// changed. A cancellation, timeout or replaced source never authorizes retry.
    public static func mayContinueWithFinder(userAccepted: Bool, originalIdentityStillMatches: Bool,
        errorDomain: String?, errorCode: Int?) -> Bool {
        userAccepted && originalIdentityStillMatches && errorCode != -128 && errorCode != -1712
            && !(errorDomain == NSCocoaErrorDomain && errorCode == NSUserCancelledError)
    }

    public static func validate(_ request: ApplicationBundleRemovalRequest) throws {
        guard BundleIdentifierValidator.isValid(request.bundleIdentifier),
              !request.bundleIdentifier.lowercased().hasPrefix("com.apple."),
              request.bundleIdentifier != "com.labrioche.StorageScope",
              request.url.pathExtension.lowercased() == "app",
              request.identity.fileType == UInt16(S_IFDIR),
              DeletionSafetyPolicy.allowsVerifiedApplicationAssociation(request.url,
                bundleIdentifier: request.bundleIdentifier, isDirectory: true),
              Bundle(url: request.url)?.bundleIdentifier == request.bundleIdentifier else {
            throw TrashError.protectedItem(request.url.path)
        }
        let info = Bundle(url: request.url)?.infoDictionary ?? [:]
        guard !ApplicationRemovalPolicy.requiresOfficialUninstaller(at: request.url, bundleIdentifier: request.bundleIdentifier,
                declaredHelpers: Array((info["SMPrivilegedExecutables"] as? [String: Any] ?? [:]).keys)) else {
            throw TrashError.operationFailed(path: request.url.path, message: "Cette application exige sa méthode officielle de désinstallation.")
        }
        var ancestor = request.url.standardizedFileURL
        while ancestor.path != "/" {
            let values = try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey])
            guard values.isSymbolicLink != true, values.isUbiquitousItem != true else {
                throw TrashError.protectedItem(request.url.path)
            }
            ancestor.deleteLastPathComponent()
        }
        guard identity(request.url) == request.identity else { throw TrashError.identityChanged(request.url.path) }
    }

    public func remove(_ request: ApplicationBundleRemovalRequest, allowFinderAuthorization: Bool = false) async -> ApplicationBundleRemovalOutcome {
        do { try Self.validate(request) }
        catch { return .init(.failed, message: error.localizedDescription) }
        if Task.isCancelled { return .init(.cancelled) }
        try? OperationJournal.append(operation: "désinstallation", path: request.url.path, status: "préparé")
        var response: RecycleResponse = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    do { try Self.validate(request) }
                    catch { continuation.resume(returning: RecycleResponse(message: error.localizedDescription)); return }
                    NSWorkspace.shared.recycle([request.url]) { locations, error in
                        let failure = error as NSError?
                        let destination = locations.first { $0.key.standardizedFileURL.path == request.url.standardizedFileURL.path }?.value
                        continuation.resume(returning: RecycleResponse(url: destination,
                            domain: failure?.domain, code: failure?.code, message: failure?.localizedDescription))
                    }
                }
        }
        // The workspace service can reject root ownership even when the current
        // account may move the bundle. Foundation still enforces the account's
        // filesystem/TCC permissions and never substitutes permanent deletion.
        if Self.isPermissionFailure(response), Self.identity(request.url) == request.identity {
            do {
                try Self.validate(request)
                var destination: NSURL?
                try FileManager.default.trashItem(at: request.url, resultingItemURL: &destination)
                response = RecycleResponse(url: destination as URL?)
            } catch {
                let error = error as NSError
                response = RecycleResponse(domain: error.domain, code: error.code, message: error.localizedDescription)
            }
        }
        if Self.mayContinueWithFinder(userAccepted: allowFinderAuthorization,
            originalIdentityStillMatches: Self.identity(request.url) == request.identity,
            errorDomain: response.domain, errorCode: response.code) {
            // Only the explicit Continue action can request Finder automation.
            // First retry the system operation: newly granted App Management may
            // already suffice, without asking for another permission.
            response = await Task.detached(priority: .userInitiated) { Self.recycleWithFinder(request) }.value
        }
        if Self.identity(request.url) == nil, response.url == nil {
            response.url = Self.findTrashedBundle(request)
        }
        let code = response.code.map(String.init) ?? "aucun"
        try? OperationJournal.append(operation: "désinstallation — " + response.backend, path: request.url.path,
            status: "réponse système", message: "Domaine=\(response.domain ?? "aucun") ; code=\(code) ; \(response.message ?? "pas de message")")
        let result: ApplicationBundleRemovalOutcome
        if let destination = response.url, Self.identity(destination) == request.identity,
           Self.identity(request.url) == nil {
            result = .init(.trashed, resultingURL: destination)
        } else if Self.identity(request.url) != request.identity {
            result = .init(.notConfirmed, message: "L’application a été déplacée ou remplacée, mais le résultat n’a pas pu être confirmé. Aucun fichier associé n’a été touché. Actualisez pour vérifier son état.")
        } else if response.code == -128 || response.code == Int(userCanceledErr) || (response.domain == NSCocoaErrorDomain && response.code == NSUserCancelledError) {
            result = .init(.cancelled, message: "L’autorisation a été annulée. Aucun fichier associé n’a été touché.")
        } else if response.code == -1743 {
            result = .init(.authorizationDenied, message: "L’autorisation d’Automatisation du Finder a été refusée. Activez StorageScope → Finder dans Confidentialité et sécurité → Automatisation, puis continuez.")
        } else if response.code == -1712 {
            result = .init(.notConfirmed, message: "Le Finder n’a pas répondu à temps. Vérifiez son éventuelle fenêtre d’autorisation et actualisez l’inventaire avant toute nouvelle tentative. Aucun fichier associé n’a été touché.")
        } else if response.backend != "Finder", response.code == nil, response.url == nil {
            result = .init(.authorizationRequired, message: "Le déplacement direct n’a pas abouti. Continuez avec le Finder pour obtenir la confirmation du système. Les données associées sont conservées.")
        } else if Self.isPermissionFailure(response) {
            result = .init(allowFinderAuthorization ? .authorizationDenied : .authorizationRequired,
                message: response.backend == "Finder"
                    ? "Le Finder a refusé le déplacement malgré la demande d’autorisation. Vérifiez la fenêtre administrateur du Finder ou les restrictions de cette application. Aucun fichier associé n’a été touché. (Code \(code))"
                    : "macOS a refusé le déplacement direct. Gestion des apps et les droits administrateur sont distincts : « Autoriser et continuer » permet au Finder de présenter la demande système nécessaire. Aucun fichier associé n’a été touché.")
        } else {
            result = .init(.failed, message: response.message ?? "\(response.backend) n’a déplacé aucun élément et n’a fourni aucune destination vérifiable. L’application est toujours à son emplacement ; aucun fichier associé n’a été touché. Consultez l’historique local pour le détail de cette tentative.")
        }
        try? OperationJournal.append(operation: "désinstallation", path: request.url.path,
            status: result.status == .trashed ? "corbeille" : "non confirmé", message: result.message)
        return result
    }

    private struct RecycleResponse: Sendable {
        var backend: String = "macOS"
        var url: URL? = nil
        var domain: String? = nil
        var code: Int? = nil
        var message: String? = nil
    }

    private static func isPermissionFailure(_ result: RecycleResponse) -> Bool {
        (result.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(result.code ?? 0))
            || (result.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(result.code ?? 0))
            || [Int(permErr), -5000].contains(result.code ?? 0)
    }

    private static func recycleWithFinder(_ request: ApplicationBundleRemovalRequest) -> RecycleResponse {
        autoreleasepool {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, FinderRecycleProtocol.eventClass, FinderRecycleProtocol.eventID, true)
            guard permission == noErr else { return RecycleResponse(backend: "Finder", domain: NSOSStatusErrorDomain, code: Int(permission), message: "Le Finder n’a pas été autorisé.") }
            do {
                try validate(request) // The authorization dialog may have stayed open.
                let event = FinderRecycleProtocol.deleteEvent(for: request.url)
                let reply = try event.sendEvent(options: FinderRecycleProtocol.sendOptions, timeout: 120)
                if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                    return RecycleResponse(backend: "Finder", domain: NSOSStatusErrorDomain, code: Int(error.int32Value),
                        message: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue)
                }
                let object = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
                var address = FinderRecycleProtocol.fileURL(object)
                if address == nil, let object = FinderRecycleProtocol.firstObject(object),
                   object.descriptorType == typeObjectSpecifier,
                   let query = FinderRecycleProtocol.urlPropertyEvent(for: object),
                   let answer = try? query.sendEvent(options: [.waitForReply, .neverInteract], timeout: 10) {
                    address = FinderRecycleProtocol.fileURL(answer.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
                }
                return RecycleResponse(backend: "Finder", url: address,
                    message: address == nil ? "Le Finder n’a fourni aucune destination. Type de réponse : \(reply.descriptorType)." : nil)
            } catch {
                let error = error as NSError
                return RecycleResponse(backend: "Finder", domain: error.domain, code: error.code, message: error.localizedDescription)
            }
        }
    }

    private static func findTrashedBundle(_ request: ApplicationBundleRemovalRequest) -> URL? {
        // Verify a missing source by inode in the current account's trash only.
        // Never retry the destructive command merely because Finder returned no URL.
        var roots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)]
        if let volumeTrash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                appropriateFor: request.url.deletingLastPathComponent(), create: false) { roots.append(volumeTrash) }
        for root in Set(roots) {
            guard let metadata = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]), metadata.isSymbolicLink != true,
                  let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]) else { continue }
            for case let candidate as URL in entries {
                if identity(candidate) == request.identity, Bundle(url: candidate)?.bundleIdentifier == request.bundleIdentifier { return candidate }
            }
        }
        return nil
    }

    private static func identity(_ url: URL) -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return FileIdentity(deviceID: FileIdentity.deviceID(fromRawValue: value.st_dev), inode: UInt64(value.st_ino), fileType: UInt16(value.st_mode & S_IFMT))
    }
}
