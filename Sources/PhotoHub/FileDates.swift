import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Die drei Datumsangaben, die der Finder zu einer Datei zeigt: Erstellt, Geändert, Hinzugefügt.
struct FileDates: Sendable, Equatable {
    var created: Date?
    var modified: Date?
    var added: Date?

    static func all(_ date: Date) -> FileDates {
        FileDates(created: date, modified: date, added: date)
    }

    static func read(_ url: URL) -> FileDates {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        return FileDates(created: values?.creationDate, modified: values?.contentModificationDate, added: values?.addedToDirectoryDate)
    }

    /// Stimmen alle vorhandenen Angaben (auf die Sekunde) mit `date` überein? Was das Dateisystem nicht kennt, zählt nicht.
    func matches(_ date: Date) -> Bool {
        [created, modified, added].allSatisfy { value in value.map { abs($0.timeIntervalSince(date)) < 1 } ?? true }
    }

    /// Schreibt die vorhandenen Angaben. Der Pfad ist Text, damit Umlaute im Namen nicht zerlegt werden.
    @discardableResult
    static func write(_ dates: FileDates, toPath path: String) -> Bool {
        var attributes: [FileAttributeKey: Any] = [:]
        attributes[.creationDate] = dates.created
        attributes[.modificationDate] = dates.modified
        var success = true
        if !attributes.isEmpty {
            do { try FileManager.default.setAttributes(attributes, ofItemAtPath: path) } catch { success = false }
        }
        if let added = dates.added, !setAddedDate(added, path: path) { success = false }
        return success
    }

    /// „Hinzugefügt“ kennt `FileManager` nicht, `setattrlist` mit ATTR_CMN_ADDEDTIME schon. Sonst zeigt der Finder
    /// dort den Zeitpunkt, an dem die Datei in den Ordner kam.
    private static func setAddedDate(_ date: Date, path: String) -> Bool {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        let seconds = date.timeIntervalSince1970.rounded(.down)
        var time = timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
        return setattrlist(path, &attributes, &time, MemoryLayout<timespec>.size, 0) == 0
    }
}

/// Aufnahmezeit aus den Metadaten – für Exporter und „Bilder-Datum korrigieren“ dieselbe Logik.
enum CaptureDate {
    static func isMovie(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
    }

    /// Wie im Skript `organize_photos.py`: Aufnahme- vor Digitalisierungs- vor Änderungsdatum aus den Metadaten.
    /// Fotos über ImageIO (mit EXIF-Zeitzone, sonst Ortszeit), Videos über AVFoundation. nil ohne Zeitangabe.
    static func read(_ url: URL) async -> Date? {
        isMovie(url) ? await movie(url) : image(url)
    }

    static func movie(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// Liest nur den Dateikopf – blockiert kurz, gehört deshalb auf GCD-Threads (`PhotoScanner.parallelMap`).
    static func image(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let candidates: [(Any?, Any?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifOffsetTimeOriginal]),
            (exif[kCGImagePropertyExifDateTimeDigitized], exif[kCGImagePropertyExifOffsetTimeDigitized]),
            (tiff[kCGImagePropertyTIFFDateTime], exif[kCGImagePropertyExifOffsetTime]),
        ]
        for (value, offset) in candidates {
            if let text = value as? String, let date = exifDate(text, offset: offset as? String) { return date }
        }
        return nil
    }

    /// „2026:08:01 14:30:00“ plus optional „+02:00“.
    private static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if let offset, let zone = timeZone(fromOffset: offset) { formatter.timeZone = zone }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let parts = offset.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let sign = parts[0].hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: hours * 3600 + sign * minutes * 60)
    }
}
