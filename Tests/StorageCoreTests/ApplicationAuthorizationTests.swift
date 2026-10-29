import Darwin
import CoreServices
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import StorageCore

private actor RefusingBundleRemover: ApplicationBundleRemoving {
    let status: ApplicationBundleRemovalStatus
    private(set) var calls = 0
    init(_ status: ApplicationBundleRemovalStatus) { self.status = status }
    func remove(_ request: ApplicationBundleRemovalRequest, allowFinderAuthorization: Bool) async -> ApplicationBundleRemovalOutcome {
        calls += 1; return .init(status, message: "Disposable authorization refusal")
    }
}

func testApplicationAuthorizationBoundaries() async throws {
    // Verify against Finder's actual installed scripting dictionary, not only
    // our constants. The 3.6.0 'aevt/delo' command fails this regression check.
    let dictionary = try XMLDocument(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.sdef"), options: [])
    let commands = try dictionary.nodes(forXPath: "//command[@name='delete']").compactMap { $0 as? XMLElement }
    try expect(commands.contains { $0.attribute(forName: "code")?.stringValue == "coredelo" }, "Finder's installed delete command contract changed")
    let file = URL(fileURLWithPath: "/Applications/Épreuve ' \\\" $() fichier.app")
    let event = FinderRecycleProtocol.deleteEvent(for: file)
    try expect(event.eventClass == 0x636f7265 && event.eventID == 0x64656c6f, "Delete must target the Finder Standard Suite, not system application events")
    let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
    try expect(direct?.numberOfItems == 1 && FinderRecycleProtocol.fileURL(direct) == file, "Exactly one literal file URL must be passed, without path interpolation")
    try expect(FinderRecycleProtocol.sendOptions.contains(.alwaysInteract) && FinderRecycleProtocol.sendOptions.contains(.canSwitchLayer), "An explicit continuation must allow Finder's system authorization UI")
    let properties = try dictionary.nodes(forXPath: "//property[@name='URL']").compactMap { $0 as? XMLElement }
    try expect(properties.contains { $0.attribute(forName: "code")?.stringValue == "pURL" }, "Finder's URL result property changed")
    let text = NSAppleEventDescriptor(string: file.absoluteString)
    try expect(FinderRecycleProtocol.fileURL(text) == file, "Finder URL property text must be decoded")
    let query = FinderRecycleProtocol.urlPropertyEvent(for: NSAppleEventDescriptor(fileURL: file))
    try expect(query?.eventClass == 0x636f7265 && query?.eventID == 0x67657464,
        "Object-reference replies must be resolved with Finder's typed read-only get command")
    try expect(FinderRecycleProtocol.fileURL(NSAppleEventDescriptor(string: "https://example.com/")) == nil, "Only local file destinations are accepted")
    try expect(SystemApplicationBundleRemover.mayContinueWithFinder(userAccepted: true, originalIdentityStillMatches: true,
        errorDomain: nil, errorCode: nil), "An empty primary reply must not silently skip the explicit Finder continuation")
    try expect(!SystemApplicationBundleRemover.mayContinueWithFinder(userAccepted: false, originalIdentityStillMatches: true,
        errorDomain: nil, errorCode: nil), "Finder must never launch without explicit continuation")
    try expect(!SystemApplicationBundleRemover.mayContinueWithFinder(userAccepted: true, originalIdentityStillMatches: false,
        errorDomain: nil, errorCode: nil), "Never retry against a missing or replaced source")
    for code in [-128, -1712, NSUserCancelledError] {
        try expect(!SystemApplicationBundleRemover.mayContinueWithFinder(userAccepted: true, originalIdentityStillMatches: true,
            errorDomain: code == NSUserCancelledError ? NSCocoaErrorDomain : NSOSStatusErrorDomain, errorCode: code),
            "Cancelled or timed-out operations must not launch another destructive method")
    }
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".StorageScope-Authorization-\(UUID().uuidString)", isDirectory: true)
    let appURL = directory.appendingPathComponent("Disposable.app", isDirectory: true)
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let info = ["CFBundleIdentifier": "com.labrioche.permission-fixture", "CFBundleName": "Disposable fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let discovery = ApplicationDiscoveryService()
    try expect(!ApplicationRemovalPolicy.requiresOfficialUninstaller(at: appURL, bundleIdentifier: "org.mozilla.firefox", declaredHelpers: ["org.mozilla.updater"]), "An updater declaration must not block Firefox's official bundle removal")
    try expect(!ApplicationRemovalPolicy.requiresOfficialUninstaller(at: appURL, bundleIdentifier: "com.google.Chrome", declaredHelpers: ["com.google.updater"]), "A shared updater must not block Chrome bundle removal")
    try expect(ApplicationRemovalPolicy.requiresOfficialUninstaller(at: appURL, bundleIdentifier: "com.example.unknown", declaredHelpers: ["com.example.helper"]), "Unknown privileged services must retain the official-method requirement")
    guard let app = await discovery.application(at: appURL), let identity = app.bundleIdentity else { throw ValidationError.failed("Disposable application was not discovered") }
    try SystemApplicationBundleRemover.validate(.init(url: appURL, bundleIdentifier: "com.labrioche.permission-fixture", identity: identity))
    let authorized = InstalledApplication(bundleURL: appURL, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName, version: app.version,
        allocatedBytesUpperBound: 0, bundleIdentity: identity, eligibility: .authorizationRequired)
    try expect(!authorized.isProtected, "An application requiring system consent must remain selectable")
    for status in [ApplicationBundleRemovalStatus.authorizationRequired, .authorizationDenied, .cancelled, .notConfirmed] {
        let backend = RefusingBundleRemover(status)
        let service = UninstallService(bundleRemover: backend)
        let plan = await service.makePlan(for: authorized)
        try expect(plan.canProceed && plan.candidates.contains { $0.group == .applicationBundle && $0.isRemovable }, "Authorization requirement incorrectly blocks the plan")
        let result = await service.uninstall(plan, selectedCandidateIDs: plan.defaultCandidateIDs)
        try expect(result.status != .succeeded && result.associatedResults.isEmpty && FileManager.default.fileExists(atPath: appURL.path), "A refused or uncertain operation must preserve the application and associated data")
        let calls = await backend.calls; try expect(calls == 1, "Never retry an uncertain operation automatically")
    }
    let wrongIdentity = FileIdentity(deviceID: identity.deviceID, inode: identity.inode &+ 1, fileType: identity.fileType)
    do {
        try SystemApplicationBundleRemover.validate(.init(url: appURL, bundleIdentifier: "com.labrioche.permission-fixture", identity: wrongIdentity))
        throw ValidationError.failed("A substituted application identity was accepted")
    } catch is TrashError {}
    for identifier in ["com.apple.Safari", "../Library", "com.labrioche.StorageScope", "com.example.other"] {
        do {
            try SystemApplicationBundleRemover.validate(.init(url: appURL, bundleIdentifier: identifier, identity: identity))
            throw ValidationError.failed("A protected or mismatched bundle identifier was accepted")
        } catch is TrashError {}
    }
    let link = directory.appendingPathComponent("Linked.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: appURL)
    do {
        try SystemApplicationBundleRemover.validate(.init(url: link, bundleIdentifier: "com.labrioche.permission-fixture", identity: identity))
        throw ValidationError.failed("A linked application was accepted")
    } catch is TrashError {}
}

func testSharedRecursiveReadBudget() async throws {
    actor Counter {
        var running = 0, peak = 0, completed = 0
        func start() { running += 1; peak = max(peak, running) }
        func finish() { running -= 1; completed += 1 }
    }
    let budget = RecursiveReadBudget(), counter = Counter()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask {
                await budget.acquire(); await counter.start()
                try? await Task.sleep(for: .milliseconds(5))
                await counter.finish(); await budget.release()
            }
        }
    }
    let peak = await counter.peak, completed = await counter.completed
    try expect(peak == 2 && completed == 12, "Recursive readers must share a budget of exactly two without dropping work")
}
