import Foundation

/// Ein Bild auf der Festplatte mit den Infos, die für Vergleich und Anzeige gebraucht werden.
struct PhotoFile: Hashable, Sendable {
    let url: URL
    let size: Int64
    let created: Date?
    /// Änderungsdatum – zusammen mit der Größe der Schlüssel für den Scan-Cache.
    var modified: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var captureDate: Date?
    /// Dateien, die zu diesem Foto gehören und mit ihm in den Papierkorb wandern:
    /// Live-Photo-Video, .AAE-Bearbeitung, .XMP-Metadaten, bei RAW+JPEG-Paaren das JPEG.
    var companions: [URL] = []
    var companionBytes: Int64 = 0

    var name: String { url.lastPathComponent }
    /// Größe samt Begleitdateien – so viel Platz wird beim Löschen frei.
    var totalSize: Int64 { size + companionBytes }
    /// „+ JPG, MOV“ für die Anzeige.
    var companionSummary: String? {
        companions.isEmpty ? nil : "+ " + companions.map { $0.pathExtension.uppercased() }.joined(separator: ", ")
    }
    var pixelCount: Int { (pixelWidth ?? 0) * (pixelHeight ?? 0) }

    var dimensionsText: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    /// Dateinamen wie „IMG_1234 Kopie.jpg“, „IMG_1234 copy 2.jpg“ oder „IMG_1234 (1).jpg“.
    var looksLikeCopy: Bool {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        return base.range(of: #"([ _-](kopie|copy)( ?\d+)?|\s?\(\d+\))$"#, options: .regularExpression) != nil
    }

    /// Sortierung „behalten zuerst“: höchste Auflösung, größte Datei, kein Kopie-Name,
    /// ältestes Erstellungsdatum, kürzester Pfad.
    static func keepOrder(_ a: PhotoFile, _ b: PhotoFile) -> Bool {
        if a.pixelCount != b.pixelCount { return a.pixelCount > b.pixelCount }
        if a.size != b.size { return a.size > b.size }
        if a.looksLikeCopy != b.looksLikeCopy { return !a.looksLikeCopy }
        let dateA = a.created ?? .distantFuture
        let dateB = b.created ?? .distantFuture
        if dateA != dateB { return dateA < dateB }
        if a.url.path.count != b.url.path.count { return a.url.path.count < b.url.path.count }
        return a.url.path < b.url.path
    }
}

/// Wonach gesucht wird.
struct FindOptions: Equatable, Sendable {
    var identical = true
    var compressed = true
    var motif = true
    var minimumMotifSize = 3
    var tolerance = DuplicateFinder.defaultTolerance

    /// Für komprimierte Kopien und gleiche Motive müssen die Bilder selbst analysiert werden.
    var needsImageAnalysis: Bool { compressed || motif }
    var isEmpty: Bool { !identical && !compressed && !motif }
}

/// Rolle einer Datei innerhalb ihrer Gruppe.
enum PhotoRole: Sendable {
    /// Beste Version eines Fotos, von dem es Kopien gibt.
    case best
    /// Byte für Byte gleiche Kopie.
    case identicalCopy
    /// Dasselbe Foto in schlechterer Qualität (verkleinert oder stärker komprimiert).
    case compressed
    /// Andere Aufnahme mit gleichem Bildaufbau und gleicher Qualität (z. B. Serienbild mit gleicher Pose).
    case sameMotif
}

/// Dateien, die zusammen angezeigt werden. Die erste Datei ist die beste.
struct DuplicateGroup: Sendable {
    enum Kind: Sendable {
        case copies
        case motif
    }

    var kind: Kind
    var files: [PhotoFile]
    var roles: [URL: PhotoRole]
    /// Vorschlag zum Löschen: Kopien, je nach gewählten Optionen.
    var suggestedMarks: Set<URL>
    /// Fotos, auf denen jemand die Augen geschlossen hat (nur in Motiv-Gruppen geprüft).
    var closedEyes: Set<URL> = []
    /// Aufnahmen, die deutlich unschärfer sind als die schärfste ihrer Motiv-Gruppe.
    var blurry: Set<URL> = []

    var suggestedBytes: Int64 { files.filter { suggestedMarks.contains($0.url) }.reduce(0) { $0 + $1.totalSize } }
    var duplicateCount: Int { files.count - 1 }

    var title: String {
        if kind == .motif { return "Gleiches Motiv" }
        let present = Set(roles.values)
        switch (present.contains(.identicalCopy), present.contains(.compressed)) {
        case (true, true): return "Bytegleiche & komprimierte Kopien"
        case (true, false): return "Bytegleiche Kopien"
        case (false, true): return "Komprimierte Kopien"
        case (false, false): return "Ähnliche Bilder"
        }
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// „1 Datei“ / „3 Dateien“ – mit Tausenderpunkten.
func plural(_ count: Int, _ one: String, _ many: String) -> String {
    "\(count.formatted()) \(count == 1 ? one : many)"
}
