import Foundation
import UniformTypeIdentifiers

/// Setzt Erstellt, Geändert und Hinzugefügt von Fotos und Videos auf die Aufnahmezeit aus ihren Metadaten –
/// dieselbe Logik wie beim Kopieren im Tab „Apple Fotos Export“, aber für Dateien, die schon irgendwo liegen.
/// Bilddaten bleiben unverändert; `undo` stellt die alten Daten wieder her.
enum DateFixer {
    struct Item: Sendable {
        let url: URL
        /// Pfad als Text – `URL` zerlegt Umlaute, geschrieben wird byte-genau.
        let path: String
        let captureDate: Date
        let current: FileDates
    }

    struct Plan: Sendable {
        var toFix: [Item] = []
        var correctCount = 0
        /// Fotos und Videos ohne Aufnahmezeit in den Metadaten – bleiben unverändert.
        var withoutDate: [URL] = []
        /// Nur in iCloud, nicht auf diesem Mac – Lesen würde sie herunterladen.
        var notDownloadedCount = 0

        var checkedCount: Int { toFix.count + correctCount + withoutDate.count }
    }

    struct Outcome: Sendable {
        struct Change: Sendable {
            let path: String
            let previous: FileDates
        }
        var changed: [Change] = []
        var failures: [String] = []
        var wasCancelled = false
    }

    // MARK: - Prüfen

    static func plan(folder: URL, recursive: Bool, progress: @escaping PhotoScanner.ProgressHandler) async throws -> Plan {
        var plan = Plan()
        let files = try mediaFiles(in: folder, recursive: recursive, notDownloaded: &plan.notDownloadedCount, progress: progress)
        let images = files.filter { !CaptureDate.isMovie($0) }
        let movies = files.filter(CaptureDate.isMovie)

        // Fotos parallel auf GCD-Threads (ImageIO blockiert), Videos über die asynchrone AVFoundation-Schnittstelle.
        var dates = try await PhotoScanner.parallelMap(images, message: "Lese Aufnahmezeit der Fotos …", progress: progress) { url in
            autoreleasepool { CaptureDate.image(url) }
        }
        progress(ScanProgress(message: "Lese Aufnahmezeit der Videos …", done: 0, total: movies.count))
        for (index, url) in movies.enumerated() {
            try Task.checkCancellation()
            dates.append(await CaptureDate.movie(url))
            progress(ScanProgress(message: "Lese Aufnahmezeit der Videos …", done: index + 1, total: movies.count))
        }

        for (url, date) in zip(images + movies, dates) {
            guard let date else {
                plan.withoutDate.append(url)
                continue
            }
            let current = FileDates.read(url)
            if current.matches(date) {
                plan.correctCount += 1
            } else {
                plan.toFix.append(Item(url: url, path: url.path, captureDate: date, current: current))
            }
        }
        plan.toFix.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return plan
    }

    /// Fotos und Videos im Ordner. Überspringt wie die Duplikatsuche versteckte Dateien, Pakete (Fotos-Mediathek –
    /// darin wird nie etwas verändert) und NAS-Vorschauordner.
    private static func mediaFiles(in folder: URL, recursive: Bool, notDownloaded: inout Int,
                                   progress: PhotoScanner.ProgressHandler) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentTypeKey, .ubiquitousItemDownloadingStatusKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: options,
                                                              errorHandler: { _, _ in true }) else {
            throw ScanError.folderNotReadable(folder)
        }
        var files: [URL] = []
        progress(ScanProgress(message: "Suche Fotos und Videos …"))
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if PhotoScanner.ignoredFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let type = values.contentType,
                  type.conforms(to: .image) || type.conforms(to: .audiovisualContent) else { continue }
            if let status = values.ubiquitousItemDownloadingStatus, status != .current {
                notDownloaded += 1
                continue
            }
            files.append(url)
            if files.count % 250 == 0 { progress(ScanProgress(message: "Suche Fotos und Videos …", done: files.count)) }
        }
        return files
    }

    // MARK: - Korrigieren

    static func apply(_ plan: Plan, progress: @escaping PhotoScanner.ProgressHandler) -> Outcome {
        var outcome = Outcome()
        let total = plan.toFix.count
        progress(ScanProgress(message: "Korrigiere Datum …", done: 0, total: total))
        for (index, item) in plan.toFix.enumerated() {
            if Task.isCancelled {
                outcome.wasCancelled = true
                break
            }
            guard FileManager.default.fileExists(atPath: item.path) else {
                outcome.failures.append("\(item.url.lastPathComponent): nicht mehr vorhanden")
                continue
            }
            let previous = FileDates.read(item.url)
            if FileDates.write(.all(item.captureDate), toPath: item.path) {
                outcome.changed.append(.init(path: item.path, previous: previous))
            } else {
                // Teilweise geschrieben? Dann den alten Stand wiederherstellen.
                FileDates.write(previous, toPath: item.path)
                outcome.failures.append("\(item.url.lastPathComponent): Datum ließ sich nicht setzen")
            }
            if (index + 1) % 50 == 0 || index + 1 == total { progress(ScanProgress(message: "Korrigiere Datum …", done: index + 1, total: total)) }
        }
        return outcome
    }

    /// Stellt die vorherigen Daten wieder her. Gibt die Dateien zurück, bei denen das nicht ging.
    static func undo(_ outcome: Outcome) -> [String] {
        outcome.changed.reversed().compactMap { change in
            FileDates.write(change.previous, toPath: change.path) ? nil : (change.path as NSString).lastPathComponent
        }
    }
}
