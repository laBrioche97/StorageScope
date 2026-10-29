import AppKit
import ImageIO

private struct IconPixels: @unchecked Sendable { let image: CGImage }

/// Only immutable pixels cross into AppKit. Large .icns decoding never runs in a view update.
private actor IconRasterizer {
    func decode(_ bundle: URL) -> IconPixels? {
        guard let name = Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return nil }
        let filename = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
        let icon = bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(filename)
        guard let values = try? icon.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(icon as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return IconPixels(image: image)
    }
}

@MainActor
final class SessionIconCache {
    private let images = NSCache<NSString, NSImage>()
    private var order: [String] = []
    private var loading: [String: Task<Void, Never>] = [:]
    private var validatedKeys: [String: String] = [:]
    private let rasterizer = IconRasterizer()
    init() { images.totalCostLimit = 64 * 1024 * 1024 }
    func refreshValidation() { validatedKeys.removeAll() }

    func load(for url: URL, version: String? = nil) async -> NSImage {
        let request = url.standardizedFileURL.path + "|" + (version ?? "")
        let key: String
        if let validated = validatedKeys[request] { key = validated }
        else {
        key = await Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey])
            return "\(request)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values?.fileResourceIdentifier))"
        }.value
        validatedKeys[request] = key
        }
        if let image = images.object(forKey: key as NSString) { touch(key); return image }
        if let task = loading[key] { await task.value }
        else {
            let task = Task { @MainActor in
                await Task.yield()
                let pixels = await rasterizer.decode(url)
                let image = pixels.map { NSImage(cgImage: $0.image, size: NSSize(width: 128, height: 128)) } ?? makeThumbnail(url)
                images.setObject(image, forKey: key as NSString, cost: 128 * 128 * 4)
                touch(key)
            }
            loading[key] = task
            await task.value
            loading[key] = nil
        }
        return images.object(forKey: key as NSString) ?? NSImage(systemSymbolName: "app", accessibilityDescription: "Application")!
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 1024 { images.removeObject(forKey: order.removeFirst() as NSString) }
        if validatedKeys.count > 2048 { validatedKeys.removeAll() }
    }

    func image(for url: URL, version: String? = nil) -> NSImage {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey])
        let key = "\(url.standardizedFileURL.path)|\(version ?? "")|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values?.fileResourceIdentifier))" as NSString
        if let image = images.object(forKey: key) { return image }
        let thumbnail = makeThumbnail(url)
        images.setObject(thumbnail, forKey: key, cost: 128 * 128 * 4)
        touch(key as String)
        return thumbnail
    }

    private func makeThumbnail(_ url: URL) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let thumbnail = NSImage(size: NSSize(width: 128, height: 128))
        thumbnail.lockFocus()
        source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero, operation: .sourceOver, fraction: 1)
        thumbnail.unlockFocus()
        return thumbnail
    }
}
