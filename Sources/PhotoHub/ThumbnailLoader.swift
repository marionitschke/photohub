import AppKit
import ImageIO
import QuickLookThumbnailing

/// Lädt Vorschaubilder über Quick Look (kann alle Formate, die auch der Finder anzeigt) und merkt sie sich.
/// Liefert Quick Look nichts, wird das Bild direkt mit ImageIO verkleinert.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var waiting: [URL: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 800
    }

    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let image = cache.object(forKey: url as NSURL) {
            completion(image)
            return
        }
        if waiting[url] != nil {
            waiting[url]?.append(completion)
            return
        }
        waiting[url] = [completion]

        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 184, height: 140), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage ?? Self.imageIOThumbnail(of: url)
            Task { @MainActor in
                if let image { self.cache.setObject(image, forKey: url as NSURL) }
                let callbacks = self.waiting.removeValue(forKey: url) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }

    private nonisolated static func imageIOThumbnail(of url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
