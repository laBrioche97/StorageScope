import AppKit

@MainActor
final class SessionIconCache {
    private let images = NSCache<NSString, NSImage>()
    init() { images.totalCostLimit = 64 * 1024 * 1024 }

    func image(for url: URL, version: String? = nil) -> NSImage {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey])
        let key = "\(url.standardizedFileURL.path)|\(version ?? "")|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values?.fileResourceIdentifier))" as NSString
        if let image = images.object(forKey: key) { return image }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let thumbnail = NSImage(size: NSSize(width: 128, height: 128))
        thumbnail.lockFocus()
        source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero, operation: .sourceOver, fraction: 1)
        thumbnail.unlockFocus()
        images.setObject(thumbnail, forKey: key, cost: 128 * 128 * 4)
        return thumbnail
    }
}
