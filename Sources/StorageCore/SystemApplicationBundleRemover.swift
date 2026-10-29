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
        let response: RecycleResponse
        if allowFinderAuthorization {
            // Permission UI is requested only by the explicit Continue action. The
            // typed descriptor carries the file reference; no generated shell/script.
            response = await Task.detached(priority: .userInitiated) { Self.recycleWithFinder(request) }.value
        } else {
            response = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    do { try Self.validate(request) }
                    catch { continuation.resume(returning: RecycleResponse(message: error.localizedDescription)); return }
                    NSWorkspace.shared.recycle([request.url]) { locations, error in
                        let failure = error as NSError?
                        continuation.resume(returning: RecycleResponse(url: locations[request.url],
                            domain: failure?.domain, code: failure?.code, message: failure?.localizedDescription))
                    }
                }
            }
        }
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
        } else if Self.isPermissionFailure(response) {
            result = .init(allowFinderAuthorization ? .authorizationDenied : .authorizationRequired,
                message: "macOS a refusé le déplacement. Autorisez Gestion des apps pour StorageScope ; une authentification administrateur peut aussi être nécessaire. Aucun fichier associé n’a été touché.")
        } else {
            result = .init(.failed, message: response.message ?? "Le système n’a pas confirmé la mise à la corbeille de l’application.")
        }
        try? OperationJournal.append(operation: "désinstallation", path: request.url.path,
            status: result.status == .trashed ? "corbeille" : "non confirmé", message: result.message)
        return result
    }

    private struct RecycleResponse: Sendable {
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
            let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEDelete), true)
            guard permission == noErr else { return RecycleResponse(domain: NSOSStatusErrorDomain, code: Int(permission), message: "Le Finder n’a pas été autorisé.") }
            do {
                try validate(request) // The authorization dialog may have stayed open.
                let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEDelete),
                    targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(NSAppleEventDescriptor(fileURL: request.url), forKeyword: AEKeyword(keyDirectObject))
                let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 120)
                if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                    return RecycleResponse(domain: NSOSStatusErrorDomain, code: Int(error.int32Value),
                        message: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue)
                }
                let object = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
                let file = object?.descriptorType == typeAEList ? object?.atIndex(1) : object
                let address = file?.coerce(toDescriptorType: typeFileURL).flatMap { String(data: $0.data, encoding: .utf8) }.flatMap(URL.init(string:))
                return RecycleResponse(url: address)
            } catch {
                let error = error as NSError
                return RecycleResponse(domain: error.domain, code: error.code, message: error.localizedDescription)
            }
        }
    }

    private static func identity(_ url: URL) -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return FileIdentity(deviceID: FileIdentity.deviceID(fromRawValue: value.st_dev), inode: UInt64(value.st_ino), fileType: UInt16(value.st_mode & S_IFMT))
    }
}
