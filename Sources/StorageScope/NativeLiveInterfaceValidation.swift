import AppKit
import Foundation

/// Captures the actual installed application's WindowGroup, including its native toolbar.
@MainActor
enum NativeLiveInterfaceValidation {
    static func run(model: AppModel, updates: SoftwareUpdates) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { throw CocoaError(.featureUnsupported) }
        let destination = URL(fileURLWithPath: CommandLine.arguments.last ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(20)
        while (model.applicationsAreLoading || model.applications.isEmpty || updates.checksStarted == 0) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard window.toolbar != nil, !model.applications.isEmpty, updates.checksStarted > 0 else { throw CocoaError(.fileReadUnknown) }
        if ProcessInfo.processInfo.environment["STORAGESCOPE_PROFILE_EXPLORER"] == "1" {
            try await ExplorerPerformanceValidation.run(model: model, window: window, destination: destination)
            return
        }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = NSApp.appearance
            for size in [NSSize(width: 1120, height: 800), NSSize(width: 740, height: 560)] {
                window.setContentSize(size); window.selectNextKeyView(nil)
                try await Task.sleep(for: .milliseconds(500))
                guard let view = window.contentView?.superview,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: destination.appendingPathComponent("macos-installed-applications-\(Int(size.width))-\(dark ? "dark" : "light").png"))
            }
        }
        try await CategoryLayoutValidation.run(model: model, window: window, destination: destination)
        try await ExplorerPerformanceValidation.run(model: model, window: window, destination: destination)
        let previousOffer = UserDefaults.standard.object(forKey: "lastUpdateOffer")
        let previousOfferDate = UserDefaults.standard.object(forKey: "lastUpdateOfferDate")
        defer { UserDefaults.standard.set(previousOffer, forKey: "lastUpdateOffer"); UserDefaults.standard.set(previousOfferDate, forKey: "lastUpdateOfferDate") }
        updates.presentOffer(version: "9.9.9")
        guard updates.showsOffer else { throw CocoaError(.fileReadUnknown) }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 740, height: 560))
            try await Task.sleep(for: .milliseconds(200))
            guard let view = window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("macos-update-banner-\(dark ? "dark" : "light").png"))
        }
        updates.activityChanged(true)
        guard updates.showsOffer, !updates.canInstallOffer else { throw CocoaError(.fileReadUnknown) }
        updates.activityChanged(false); updates.dismissOffer()
        guard !updates.showsOffer, updates.availableVersion != nil else { throw CocoaError(.fileReadUnknown) }
        print("PASS live installed WindowGroup, native toolbar, application inventory and keyboard focus")
    }
}
