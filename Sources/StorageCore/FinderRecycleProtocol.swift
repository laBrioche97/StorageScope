import CoreServices
import Foundation

/// Finder's Standard Suite uses 'core/delo', not the system event class 'aevt'.
/// This builder never sends an event or requests authorization by itself.
public enum FinderRecycleProtocol {
    public static let eventClass = AEEventClass(kAECoreSuite)
    public static let eventID = AEEventID(kAEDelete)
    public static var sendOptions: NSAppleEventDescriptor.SendOptions { [.waitForReply, .alwaysInteract, .canSwitchLayer] }

    public static func deleteEvent(for url: URL) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
        event.setParam(files, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    public static func firstObject(_ descriptor: NSAppleEventDescriptor?) -> NSAppleEventDescriptor? {
        descriptor?.descriptorType == typeAEList ? descriptor?.atIndex(1) : descriptor
    }

    public static func fileURL(_ descriptor: NSAppleEventDescriptor?) -> URL? {
        guard let object = firstObject(descriptor) else { return nil }
        let value = object.descriptorType == typeFileURL ? String(data: object.data, encoding: .utf8) : object.stringValue
        guard let value, let url = URL(string: value), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    /// A delete reply may contain an object specifier rather than a URL. Ask
    /// Finder for that object's URL using another typed, read-only event.
    public static func urlPropertyEvent(for object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        property.setDescriptor(object, forKeyword: AEKeyword(keyAEContainer))
        property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        property.setDescriptor(NSAppleEventDescriptor(typeCode: 0x7055524c), forKeyword: AEKeyword(keyAEKeyData)) // Finder URL ('pURL').
        guard let reference = property.coerce(toDescriptorType: typeObjectSpecifier) else { return nil }
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(reference, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
}
