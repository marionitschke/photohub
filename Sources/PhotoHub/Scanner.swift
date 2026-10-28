import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ScanProgress: Sendable {
    var message: String
    var done = 0
    var total = 0
}

/// Wahrnehmungs-Hash eines Bildes (Helligkeitsverlauf horizontal + vertikal, je 64 Bit)
/// plus das 9 × 9-Helligkeitsraster, aus dem er berechnet wurde.
struct Fingerprint: Sendable {
    var file: PhotoFile
    let horizontal: UInt64
    let vertical: UInt64
    /// Mittlere Helligkeit (0 … 255) der 81 Felder, zeilenweise.
    let grid: [UInt8]
}

enum ScanError: LocalizedError {
    case folderNotReadable(URL)

    var errorDescription: String? {
        switch self {
        case .folderNotReadable(let url): return "Der Ordner „\(url.path)“ kann nicht gelesen werden."
        }
    }
}

enum PhotoScanner {
    typealias ProgressHandler = @Sendable (ScanProgress) -> Void

    /// Ordner von NAS-Systemen und Windows, die nur Vorschaubilder oder Gelöschtes enthalten.
    static let ignoredFolders: Set<String> = ["@eaDir", "#recycle", "#snapshot", "$RECYCLE.BIN", "System Volume Information"]
    private static let quickHashBytes = 64 * 1024

    /// Sucht alle Bilder, findet byte-gleiche Dateien und berechnet – falls nötig – die Bild-Fingerabdrücke.
    /// Was der Cache schon kennt, wird nicht erneut gelesen.
    static func scan(folder: URL, recursive: Bool, pairRawWithJPEG: Bool, analyzeImages: Bool, cache: ScanCache,
                     progress: @escaping ProgressHandler) async throws -> ScanCatalog {
        let files = try findImages(in: folder, recursive: recursive, pairRawWithJPEG: pairRawWithJPEG, progress: progress)
        cache.removeEntries(in: folder, recursive: recursive, except: Set(files.flatMap { [$0.url] + $0.companions }.map(\.path)))
        let identicalSets = try await exactDuplicates(in: files, cache: cache, progress: progress)
        guard analyzeImages else {
            progress(ScanProgress(message: "Lese Bildinformationen …"))
            let withInfo = identicalSets.map { $0.map { cache.entry(for: $0)?.picture?.withMetadata($0) ?? withMetadata($0) } }
            return ScanCatalog(scannedCount: files.count, identicalSets: withInfo, fingerprints: nil)
        }
        let prints = try await fingerprints(for: files, cache: cache, progress: progress)
        progress(ScanProgress(message: "Vergleiche Bilder …"))
        // Die Fingerabdrücke enthalten schon Auflösung und Aufnahmedatum.
        let analyzed = Dictionary(uniqueKeysWithValues: prints.map { ($0.file.url, $0.file) })
        return ScanCatalog(scannedCount: files.count,
                           identicalSets: identicalSets.map { $0.map { analyzed[$0.url] ?? withMetadata($0) } },
                           fingerprints: prints)
    }

    // MARK: - Bilder finden

    /// Endungen von Begleitdateien, die zu einem Foto gleichen Namens gehören.
    private static let companionExtensions: Set<String> = ["mov", "aae", "xmp"]

    static func findImages(in folder: URL, recursive: Bool, pairRawWithJPEG: Bool = true, progress: ProgressHandler) throws -> [PhotoFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey,
                                      .contentModificationDateKey, .contentTypeKey]
        // skipsPackageDescendants überspringt u. a. Fotos-Mediatheken (*.photoslibrary) –
        // Dateien darin dürfen nie einzeln gelöscht werden.
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: options, errorHandler: { _, _ in true }) else {
            throw ScanError.folderNotReadable(folder)
        }

        let keySet = Set(keys)
        var files: [PhotoFile] = []
        var sidecars: [String: [(url: URL, size: Int64)]] = [:]
        progress(ScanProgress(message: "Suche Bilder …"))
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true {
                if ignoredFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
            if companionExtensions.contains(url.pathExtension.lowercased()) {
                sidecars[companionKey(url.deletingPathExtension()), default: []].append((url, Int64(size)))
                continue
            }
            guard let type = values.contentType, type.conforms(to: .image) else { continue }
            files.append(PhotoFile(url: url, size: Int64(size), created: values.creationDate,
                                   modified: values.contentModificationDate))
            if files.count % 250 == 0 {
                progress(ScanProgress(message: "Suche Bilder …", done: files.count))
            }
        }
        return attachCompanions(to: files, sidecars: sidecars, pairRawWithJPEG: pairRawWithJPEG)
    }

    /// Ordner + Dateiname ohne Endung, ohne Groß-/Kleinschreibung: „…/urlaub/img_1234“.
    private static func companionKey(_ urlWithoutExtension: URL) -> String {
        urlWithoutExtension.path.lowercased()
    }

    /// Hängt Begleitdateien an das Foto gleichen Namens im selben Ordner. Bei RAW+JPEG-Paaren wird das JPEG
    /// (bzw. HEIC) zur Begleitdatei des RAW und selbst nicht mehr verglichen. Gibt es mehrere Fotos mit
    /// gleichem Namen ohne eindeutiges RAW, bleiben die Begleitdateien unangetastet.
    private static func attachCompanions(to files: [PhotoFile], sidecars: [String: [(url: URL, size: Int64)]],
                                         pairRawWithJPEG: Bool) -> [PhotoFile] {
        var files = files
        var paired = Set<Int>()
        let byName = Dictionary(grouping: files.indices) { companionKey(files[$0].url.deletingPathExtension()) }
        for (name, indices) in byName {
            var owner = indices.count == 1 ? indices[0] : nil
            if owner == nil, pairRawWithJPEG {
                let raws = indices.filter { UTType(filenameExtension: files[$0].url.pathExtension)?.conforms(to: .rawImage) == true }
                if raws.count == 1 { owner = raws[0] }
            }
            guard let owner else { continue }

            func attach(_ url: URL, _ size: Int64) {
                files[owner].companions.append(url)
                files[owner].companionBytes += size
            }
            for member in indices where member != owner {
                attach(files[member].url, files[member].size)
                paired.insert(member)
            }
            // „IMG_1234.xmp“ und „IMG_1234.NEF.xmp“ (Lightroom bzw. darktable)
            for sidecar in (sidecars[name] ?? []) + indices.flatMap({ sidecars[companionKey(files[$0].url)] ?? [] }) {
                attach(sidecar.url, sidecar.size)
            }
        }
        return files.indices.filter { !paired.contains($0) }.map { files[$0] }
    }

    // MARK: - Identische Dateien

    /// Dreistufig, damit nur wenige Dateien komplett gelesen werden müssen:
    /// gleiche Größe → gleicher Hash der ersten 64 KB → gleicher SHA-256 der ganzen Datei.
    static func exactDuplicates(in files: [PhotoFile], cache: ScanCache, progress: @escaping ProgressHandler) async throws -> [[PhotoFile]] {
        var candidates = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
        guard !candidates.isEmpty else { return [] }

        let quickHashes = try await mapUsingCache(candidates, message: "Vergleiche Dateianfänge …", progress: progress,
                                                  cached: { cache.entry(for: $0)?.quickHash }) { file in
            let hash = try? sha256(of: file.url, limit: quickHashBytes)
            if let hash { cache.update(file) { $0.quickHash = hash } }
            return hash
        }
        candidates = matchingGroups(candidates, keys: quickHashes).flatMap { $0 }
        guard !candidates.isEmpty else { return [] }

        let fullHashes = try await mapUsingCache(candidates, message: "Vergleiche Dateiinhalte …", progress: progress,
                                                 cached: { cache.entry(for: $0)?.fullHash }) { file in
            let hash = try? sha256(of: file.url)
            if let hash { cache.update(file) { $0.fullHash = hash } }
            return hash
        }
        return matchingGroups(candidates, keys: fullHashes)
    }

    private static func matchingGroups(_ files: [PhotoFile], keys: [String?]) -> [[PhotoFile]] {
        var buckets: [String: [PhotoFile]] = [:]
        for (file, key) in zip(files, keys) {
            guard let key else { continue }
            buckets["\(file.size)-\(key)", default: []].append(file)
        }
        return buckets.values.filter { $0.count > 1 }
    }

    static func sha256(of url: URL, limit: Int = .max) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit
        while remaining > 0 {
            let read: Int = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else { return 0 }
                hasher.update(data: chunk)
                return chunk.count
            }
            if read == 0 { break }
            remaining -= read
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Ähnliche Bilder

    static func fingerprints(for files: [PhotoFile], cache: ScanCache, progress: @escaping ProgressHandler) async throws -> [Fingerprint] {
        let prints = try await mapUsingCache(files, message: "Analysiere Bilder …", progress: progress,
                                             cached: { cache.entry(for: $0)?.picture?.fingerprint(of: $0) }) { file in
            let print = autoreleasepool { fingerprint(of: file) }
            if let print { cache.update(file) { $0.picture = ScanCache.StoredPicture(print) } }
            return print
        }
        return prints.compactMap { $0 }
    }

    static func fingerprint(of file: PhotoFile) -> Fingerprint? {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let grid = brightnessGrid(of: thumbnail, size: 9) else { return nil }

        // dHash: Bit = 1, wenn ein Feld heller ist als sein rechter bzw. unterer Nachbar.
        var horizontal: UInt64 = 0
        var vertical: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let value = grid[row * 9 + col]
                horizontal = horizontal << 1 | (value > grid[row * 9 + col + 1] ? 1 : 0)
                vertical = vertical << 1 | (value > grid[(row + 1) * 9 + col] ? 1 : 0)
            }
        }
        let cellPixels = Float(64) // jedes Feld ist ein Block aus 8 × 8 Pixeln
        return Fingerprint(file: withMetadata(file, source: source), horizontal: horizontal, vertical: vertical,
                           grid: grid.map { UInt8(min(255, ($0 / cellPixels).rounded())) })
    }

    /// Verkleinert das Bild auf size × size Felder mittlerer Helligkeit.
    private static func brightnessGrid(of image: CGImage, size: Int) -> [Float]? {
        let scale = 8
        let side = size * scale
        var pixels = [UInt8](repeating: 255, count: side * side) // weißer Hintergrund für Transparenz
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var grid = [Float](repeating: 0, count: size * size)
        for y in 0..<side {
            for x in 0..<side {
                grid[(y / scale) * size + x / scale] += Float(pixels[y * side + x])
            }
        }
        return grid
    }

    // MARK: - Metadaten

    static func withMetadata(_ file: PhotoFile) -> PhotoFile {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return file }
        return withMetadata(file, source: source)
    }

    private static func withMetadata(_ file: PhotoFile, source: CGImageSource) -> PhotoFile {
        var file = file
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return file }
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let rotated = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            file.pixelWidth = rotated ? height : width
            file.pixelHeight = rotated ? width : height
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            file.captureDate = exifDateFormatter.date(from: original)
        }
        return file
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    // MARK: - Parallelisierung

    /// Wendet transform auf alle Elemente an – so viele gleichzeitig, wie der Mac Kerne hat.
    ///
    /// Läuft bewusst auf GCD-Threads statt auf dem Thread-Pool von Swift Concurrency: Apple-Frameworks
    /// wie Vision nutzen intern selbst diesen Pool. Wären alle seine Threads mit blockierenden
    /// Gesichtsprüfungen belegt, käme keine mehr voran.
    static func parallelMap<T: Sendable, R: Sendable>(
        _ items: [T], message: String, progress: @escaping ProgressHandler,
        _ transform: @escaping @Sendable (T) -> R
    ) async throws -> [R] {
        let total = items.count
        let step = max(1, total / 200)
        progress(ScanProgress(message: message, done: 0, total: total))
        guard total > 0 else { return [] }

        let state = ParallelState<R>(count: total)
        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    DispatchQueue.concurrentPerform(iterations: total) { index in
                        guard !state.isCancelled else { return }
                        let finished = state.store(transform(items[index]), at: index)
                        if finished % step == 0 || finished == total {
                            progress(ScanProgress(message: message, done: finished, total: total))
                        }
                    }
                    continuation.resume()
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            state.cancel()
        }
        return state.results()
    }

    /// Übernimmt vorhandene Ergebnisse aus dem Cache und berechnet nur die fehlenden – parallel.
    /// Der Fortschritt zählt deshalb nur Dateien, die wirklich gelesen werden.
    static func mapUsingCache<R: Sendable>(
        _ files: [PhotoFile], message: String, progress: @escaping ProgressHandler,
        cached: (PhotoFile) -> R?, compute: @escaping @Sendable (PhotoFile) -> R?
    ) async throws -> [R?] {
        var results = files.map(cached)
        let missing = results.indices.filter { results[$0] == nil }
        let computed = try await parallelMap(missing.map { files[$0] }, message: message, progress: progress, compute)
        for (index, value) in zip(missing, computed) { results[index] = value }
        return results
    }
}

/// Ergebnisse und Abbruch-Status für `parallelMap`, von mehreren Threads aus beschrieben.
private final class ParallelState<R>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [R?]
    private var finished = 0
    private var cancelled = false

    init(count: Int) {
        values = [R?](repeating: nil, count: count)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Speichert ein Ergebnis und gibt zurück, wie viele inzwischen fertig sind.
    func store(_ value: R, at index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        values[index] = value
        finished += 1
        return finished
    }

    func results() -> [R] {
        lock.lock()
        defer { lock.unlock() }
        return values.map { $0! }
    }
}
