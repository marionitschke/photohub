import CoreImage
import Foundation
import ImageIO
import Vision

/// Was die Analyse einer Aufnahme ergibt: wie scharf sie ist, wie viele Gesichter sie zeigt,
/// bei wie vielen die Augen zu sind und wie gut sie getroffen sind.
struct ShotInfo: Sendable, Equatable, Codable {
    /// Kantenstärke der schärfsten Bildbereiche im Verhältnis zum Bildkontrast. Nur zwischen Aufnahmen
    /// desselben Motivs aussagekräftig.
    var sharpness: Float?
    var faceCount = 0
    var closedEyesCount = 0
    /// Mittlere Gesichtsqualität laut Vision (0 … 1): Schärfe, Licht, Ausdruck, Haltung.
    var quality: Float?

    var hasClosedEyes: Bool { closedEyesCount > 0 }
}

/// Analysiert Aufnahmen mit Apples eingebauten Frameworks – komplett auf dem Mac, ohne Internet.
enum ShotAnalyzer {
    /// Kleinere Gesichter (Anteil an der Bildhöhe) werden ignoriert – dort ist die Augenerkennung unzuverlässig.
    private static let minimumFaceHeight = 0.06
    private static let analysisSize = 2048
    /// Die Schärfe wird immer bei dieser Größe gemessen, damit Aufnahmen verschiedener Auflösung vergleichbar sind.
    /// Kleiner verkleinert, gingen Verwackler von wenigen Pixeln verloren.
    private static let sharpnessSize = 2048
    private static let sharpnessTile = 64

    static func analyze(_ files: [PhotoFile], cache: ScanCache,
                        progress: @escaping PhotoScanner.ProgressHandler) async throws -> [URL: ShotInfo] {
        let results = try await PhotoScanner.mapUsingCache(files, message: "Prüfe Schärfe, Gesichter und Augen …", progress: progress,
                                                           cached: { cache.entry(for: $0)?.shot }) { file in
            let info = autoreleasepool { analyze(file.url) }
            if let info { cache.update(file) { $0.shot = info } }
            return info
        }
        var shots: [URL: ShotInfo] = [:]
        for (file, info) in zip(files, results) { shots[file.url] = info ?? ShotInfo() }
        return shots
    }

    static func analyze(_ url: URL) -> ShotInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var info = ShotInfo()
        info.sharpness = sharpness(of: image)

        // Augen: Core-Image-Gesichtserkennung mit eingebauter Blinzel-Erkennung.
        let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image), options: [CIDetectorEyeBlink: true]) ?? []
        let minimumHeight = Double(image.height) * minimumFaceHeight
        for case let face as CIFaceFeature in features where Double(face.bounds.height) >= minimumHeight {
            info.faceCount += 1
            if face.leftEyeClosed && face.rightEyeClosed { info.closedEyesCount += 1 }
        }

        // Gesichtsqualität: Vision.
        let request = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let scores = (request.results ?? [])
            .filter { Double($0.boundingBox.height) >= minimumFaceHeight }
            .compactMap(\.faceCaptureQuality)
        if !scores.isEmpty {
            info.faceCount = max(info.faceCount, scores.count)
            info.quality = scores.reduce(0, +) / Float(scores.count)
        }
        return info
    }

    /// Schärfe als Produkt zweier Maße, beide in den detailreichsten Bildfeldern gemessen – meist das Motiv im Fokus,
    /// nicht der unscharfe Hintergrund oder Himmel:
    /// - Detailenergie der schwächeren Richtung (zweite Ableitung waagerecht bzw. senkrecht, geteilt durch den
    ///   Bildkontrast). Verwackeln verwischt Kanten nur quer zur Bewegung – das fällt so voll ins Gewicht.
    /// - Kantensteilheit: stärkster Helligkeitsanstieg im Verhältnis zum Helligkeitsumfang eines Feldes.
    ///   Reagiert auf jede Unschärfe und kaum auf Bildrauschen.
    /// Vorher wird leicht geglättet, damit Bildrauschen nicht als Detail zählt. Die Belichtung ändert den Wert kaum.
    /// Gemessen: verwackelte oder unscharfe Aufnahmen 0,45–0,8 der scharfen; scharfe Aufnahmen desselben Motivs,
    /// auch dunklere oder neu komprimierte, 0,96–1,08.
    static func sharpness(of image: CGImage) -> Float? {
        let scale = Double(sharpnessSize) / Double(max(image.width, image.height))
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        guard width > 16, height > 16 else { return nil }
        var gray = [UInt8](repeating: 255, count: width * height) // weißer Hintergrund für Transparenz
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 3 × 3-Mittelwert, erst zeilen-, dann spaltenweise.
        var rowSums = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 1..<(width - 1) {
                rowSums[row + x] = Float(gray[row + x - 1]) + Float(gray[row + x]) + Float(gray[row + x + 1])
            }
        }
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                pixels[row + x] = (rowSums[row - width + x] + rowSums[row + x] + rowSums[row + width + x]) / 9
            }
        }

        let tile = sharpnessTile
        let columns = (width + tile - 1) / tile
        let tileCount = columns * ((height + tile - 1) / tile)
        var energyX = [Double](repeating: 0, count: tileCount), energyY = energyX, counts = energyX
        var steepest = [Float](repeating: 0, count: tileCount)
        var darkest = [Float](repeating: .infinity, count: tileCount), brightest = steepest
        var sum = 0.0, squares = 0.0
        for y in 3..<(height - 3) {
            let row = y * width
            let tileRow = (y / tile) * columns
            for x in 3..<(width - 3) {
                let i = row + x
                let value = pixels[i]
                let curveX = 2 * value - pixels[i - 2] - pixels[i + 2]
                let curveY = 2 * value - pixels[i - 2 * width] - pixels[i + 2 * width]
                let slopeX = pixels[i + 1] - pixels[i - 1]
                let slopeY = pixels[i + width] - pixels[i - width]
                let t = tileRow + x / tile
                energyX[t] += Double(curveX * curveX)
                energyY[t] += Double(curveY * curveY)
                counts[t] += 1
                steepest[t] = max(steepest[t], (slopeX * slopeX + slopeY * slopeY).squareRoot())
                darkest[t] = min(darkest[t], value)
                brightest[t] = max(brightest[t], value)
                sum += Double(value)
                squares += Double(value * value)
            }
        }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        let mean = sum / total
        let contrast = max((squares / total - mean * mean).squareRoot(), 4) // fast einfarbig: Rauschen nicht überbewerten

        // Detailenergie: die 10 % energiereichsten Felder, schwächere Richtung.
        let byEnergy = (0..<tileCount).filter { counts[$0] > 0 }.sorted { energyX[$0] + energyY[$0] > energyX[$1] + energyY[$1] }
        let detailed = byEnergy.prefix(max(1, byEnergy.count / 10))
        let pixelCount = detailed.reduce(0) { $0 + counts[$1] }
        let weakerEnergy = min(detailed.reduce(0) { $0 + energyX[$1] }, detailed.reduce(0) { $0 + energyY[$1] })
        let detail = (weakerEnergy / pixelCount).squareRoot() / contrast

        // Kantensteilheit: Median über die 20 % kontrastreichsten Felder.
        let ranges: [Float] = (0..<tileCount).map { counts[$0] > 0 ? brightest[$0] - darkest[$0] : 0 }
        let byRange = (0..<tileCount).filter { ranges[$0] > 8 }.sorted { ranges[$0] > ranges[$1] }
        guard !byRange.isEmpty else { return nil }
        let steepness = byRange.prefix(max(1, byRange.count / 5)).map { steepest[$0] / ranges[$0] }.sorted()
        return Float(detail) * steepness[steepness.count / 2]
    }
}
