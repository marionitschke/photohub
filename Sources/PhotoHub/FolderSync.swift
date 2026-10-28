import Foundation
import UniformTypeIdentifiers

/// Ergänzt Ordner B um die Fotos und Videos aus Ordner A, die dort fehlen: Sie werden aus A in denselben Unterordner
/// in B verschoben. „Fehlt“ heißt, dass nirgends in B eine Datei mit gleichem Inhalt liegt – Name und Unterordner in B
/// spielen keine Rolle. Was danach noch in A liegt, gibt es also auch in B.
/// - Verglichen wird über SHA-256 der ganzen Datei (mit dem Scan-Cache), nicht nur über Anfang und Ende wie beim
///   Exporter: Ein Irrtum hieße hier, dass ein Foto in A bleibt, das in B gar nicht liegt.
/// - Ist der Name in B schon vergeben, wird wie beim Exporter durchnummeriert (`IMG_1_1.HEIC`) – Dateien gleichen
///   Namens (Live Photo, RAW+JPEG, .AAE) gemeinsam.
/// - Erstellt, Geändert und Hinzugefügt bleiben wie in A. `undo` verschiebt alles zurück.
enum FolderSync {
    struct Move: Sendable {
        /// Pfade als Text – `URL` zerlegt Umlaute, die Namen sollen Byte für Byte bleiben.
        let sourcePath: String
        let targetPath: String
        /// Pfad unterhalb von A bzw. B, für die Anzeige.
        let relativeSource: String
        let relativeTarget: String
        let size: Int64

        var source: URL { URL(fileURLWithPath: sourcePath) }
        var isRenamed: Bool { (relativeSource as NSString).lastPathComponent != (relativeTarget as NSString).lastPathComponent }
    }

    struct Plan: Sendable {
        var moves: [Move] = []
        /// Liegen mit gleichem Inhalt schon in B – bleiben in A.
        var presentCount = 0
        /// Gleicher Inhalt wie eine andere Datei aus A, die nach B wandert – bleibt in A.
        var duplicateCount = 0
        /// Nur in iCloud, nicht auf diesem Mac: In A bleiben sie liegen, in B werden sie nicht verglichen.
        /// Lesen würde sie herunterladen.
        var notDownloadedInSource = 0
        var notDownloadedInDestination = 0
        /// Andere Dateien in A (keine Fotos oder Videos) – bleiben liegen.
        var otherFileCount = 0
        /// A und B liegen auf verschiedenen Laufwerken: Verschieben heißt kopieren und in A löschen.
        var acrossVolumes = false

        var checkedCount: Int { moves.count + presentCount + duplicateCount }
        var moveBytes: Int64 { moves.reduce(0) { $0 + $1.size } }
        var renameCount: Int { moves.filter(\.isRenamed).count }
    }

    /// Was beim Verschieben passiert ist – genug, um es zurückzunehmen.
    struct Outcome: Sendable {
        struct Moved: Sendable {
            let sourcePath: String
            let targetPath: String
            let dates: FileDates
        }
        var moved: [Moved] = []
        var createdDirectories: [String] = []
        /// Änderungsdatum der berührten Ordner in A und B vorher – Verschieben ändert es.
        var folderDates: [String: Date] = [:]
        var failures: [String] = []
        var wasCancelled = false
    }

    enum SyncError: LocalizedError {
        case overlapping
        case notEnoughSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .overlapping:
                return "A und B müssen zwei getrennte Ordner sein – keiner darf im anderen liegen."
            case .notEnoughSpace(let needed, let available):
                return "In B ist nicht genug Platz: Die Dateien brauchen \(needed.formattedBytes), frei sind \(available.formattedBytes)."
            }
        }
    }

    /// Begleitdateien ohne eigenen Bildtyp: Bearbeitungen aus Fotos (.AAE) und Metadaten aus Lightroom & Co. (.XMP).
    private static let sidecarExtensions: Set<String> = ["aae", "xmp"]

    // MARK: - Vergleichen

    /// Plant das Verschieben, ohne etwas zu verändern.
    static func plan(source: URL, destination: URL, cache: ScanCache, progress: @escaping PhotoScanner.ProgressHandler) async throws -> Plan {
        func normalized(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
        }
        func contains(_ outer: String, _ inner: String) -> Bool { (inner + "/").hasPrefix(outer + "/") }
        let sourceKey = normalized(source)
        let destinationKey = normalized(destination)
        if contains(sourceKey, destinationKey) || contains(destinationKey, sourceKey) { throw SyncError.overlapping }

        var plan = Plan()
        plan.acrossVolumes = !sameVolume(source, destination)
        let sourceFiles = try mediaFiles(in: source, name: "A", notDownloaded: &plan.notDownloadedInSource,
                                         others: &plan.otherFileCount, progress: progress)
        var otherFilesInDestination = 0
        let destinationFiles = try mediaFiles(in: destination, name: "B", notDownloaded: &plan.notDownloadedInDestination,
                                              others: &otherFilesInDestination, progress: progress)

        // Gleich sein können nur Dateien gleicher Größe – aus B werden nur die gelesen, deren Größe in A vorkommt.
        let sourceSizes = Set(sourceFiles.map(\.size))
        let candidates = sourceFiles + destinationFiles.filter { sourceSizes.contains($0.size) }
        let identicalSets = try await PhotoScanner.exactDuplicates(in: candidates, cache: cache, progress: progress)

        let sourcePaths = Set(sourceFiles.map(\.url.path))
        var present = Set<String>()
        var duplicates = Set<String>()
        for set in identicalSets {
            let fromSource = set.map(\.url.path).filter(sourcePaths.contains)
            if fromSource.count < set.count {
                present.formUnion(fromSource)
            } else {
                // Nur in A, dort mehrfach: Die erste Datei wandert nach B, die übrigen gibt es danach schon dort.
                duplicates.formUnion(fromSource.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.dropFirst())
            }
        }
        plan.presentCount = present.count
        plan.duplicateCount = duplicates.count

        let missing = sourceFiles.filter { !present.contains($0.url.path) && !duplicates.contains($0.url.path) }
        plan.moves = targets(for: missing, source: source, destination: destination)
        return plan
    }

    /// Fotos, Videos und ihre Begleitdateien im Ordner und allen Unterordnern. Überspringt wie die Duplikatsuche
    /// versteckte Dateien, Pakete (Fotos-Mediathek – darin wird nie etwas verändert) und NAS-Vorschauordner.
    private static func mediaFiles(in folder: URL, name: String, notDownloaded: inout Int, others: inout Int,
                                   progress: PhotoScanner.ProgressHandler) throws -> [PhotoFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey,
                                      .contentModificationDateKey, .contentTypeKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else {
            throw ScanError.folderNotReadable(folder)
        }
        let keySet = Set(keys)
        let message = "Suche Fotos und Videos in \(name) …"
        var files: [PhotoFile] = []
        progress(ScanProgress(message: message))
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true {
                if PhotoScanner.ignoredFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let isMedia = values.contentType.map { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) } ?? false
            guard isMedia || sidecarExtensions.contains(url.pathExtension.lowercased()) else {
                others += 1
                continue
            }
            if let status = values.ubiquitousItemDownloadingStatus, status != .current {
                notDownloaded += 1
                continue
            }
            guard let size = values.fileSize, size > 0 else { continue }
            files.append(PhotoFile(url: url, size: Int64(size), created: values.creationDate, modified: values.contentModificationDate))
            if files.count % 250 == 0 { progress(ScanProgress(message: message, done: files.count)) }
        }
        return files
    }

    /// Ziel jeder fehlenden Datei: derselbe Unterordner in B. Dateien gleichen Namens aus einem Ordner (Live Photo,
    /// RAW+JPEG, .AAE) bekommen gemeinsam den ersten Zusatz – „IMG_1“, „IMG_1_1“, … –, unter dem in B noch nichts liegt.
    private static func targets(for files: [PhotoFile], source: URL, destination: URL) -> [Move] {
        let fileManager = FileManager.default
        // Ziele, die dieser Lauf schon vergibt (ohne Groß-/Kleinschreibung, wie APFS).
        var claimed = Set<String>()
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        func isFree(_ path: String) -> Bool { !claimed.contains(key(path)) && !fileManager.fileExists(atPath: path) }

        let withRelative = files.map { (file: $0, relative: relativePath($0.url.path, root: source.path)) }
        let groups = Dictionary(grouping: withRelative) { key(($0.relative as NSString).deletingPathExtension) }
        var moves: [Move] = []
        for stem in groups.keys.sorted() {
            let members = groups[stem]!.sorted { $0.relative < $1.relative }
            func target(_ relative: String, _ suffix: Int) -> String {
                let directory = (relative as NSString).deletingLastPathComponent
                let name = ExportSorter.renamed((relative as NSString).lastPathComponent, suffix)
                return directory.isEmpty ? name : directory + "/" + name
            }
            var suffix = 0
            while !members.allSatisfy({ isFree(destination.path + "/" + target($0.relative, suffix)) }) { suffix += 1 }
            for member in members {
                let relativeTarget = target(member.relative, suffix)
                let targetPath = destination.path + "/" + relativeTarget
                claimed.insert(key(targetPath))
                moves.append(Move(sourcePath: member.file.url.path, targetPath: targetPath, relativeSource: member.relative,
                                  relativeTarget: relativeTarget, size: member.file.size))
            }
        }
        return moves.sorted { $0.relativeSource.localizedStandardCompare($1.relativeSource) == .orderedAscending }
    }

    /// „/A/2020/Urlaub/IMG_1.jpg“ unter „/A“ → „2020/Urlaub/IMG_1.jpg“ – Zeichen für Zeichen wie auf der Platte.
    private static func relativePath(_ path: String, root: String) -> String {
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let components = (path as NSString).pathComponents.dropFirst((root as NSString).pathComponents.count)
        return components.joined(separator: "/")
    }

    // MARK: - Verschieben

    /// Verschiebt wie geplant. Bei Abbruch bleibt es beim bis dahin Verschobenen – auch das nimmt `undo` zurück.
    static func apply(_ plan: Plan, source: URL, destination: URL, progress: @escaping PhotoScanner.ProgressHandler) throws -> Outcome {
        if plan.acrossVolumes { try checkSpace(for: plan, destination: destination) }
        let fileManager = FileManager.default
        var outcome = Outcome()
        func remember(_ directory: String) {
            guard outcome.folderDates[directory] == nil,
                  let date = (try? fileManager.attributesOfItem(atPath: directory))?[.modificationDate] as? Date else { return }
            outcome.folderDates[directory] = date
        }
        /// Legt fehlende Ordner einzeln an (für `undo`) – per `mkdir`, weil `FileManager` Umlaute im Namen zerlegt.
        func createDirectory(_ path: String) throws {
            var missing: [String] = []
            var existing = path
            while !fileManager.fileExists(atPath: existing) {
                missing.append(existing)
                existing = (existing as NSString).deletingLastPathComponent
            }
            guard !missing.isEmpty else { return }
            remember(existing)
            for directory in missing.reversed() {
                if mkdir(directory, 0o777) == 0 {
                    outcome.createdDirectories.append(directory)
                } else if errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        let total = plan.moves.count
        progress(ScanProgress(message: "Verschiebe nach B …", done: 0, total: total))
        for (index, move) in plan.moves.enumerated() {
            if Task.isCancelled {
                outcome.wasCancelled = true
                break
            }
            defer {
                if (index + 1) % 20 == 0 || index + 1 == total { progress(ScanProgress(message: "Verschiebe nach B …", done: index + 1, total: total)) }
            }
            guard fileManager.fileExists(atPath: move.sourcePath) else {
                outcome.failures.append("\(move.relativeSource): nicht mehr in A")
                continue
            }
            let directory = (move.targetPath as NSString).deletingLastPathComponent
            let name = (move.targetPath as NSString).lastPathComponent
            do {
                try createDirectory(directory)
            } catch {
                outcome.failures.append("\(move.relativeSource): Ordner in B ließ sich nicht anlegen (\(error.localizedDescription))")
                continue
            }
            // Ist das Ziel inzwischen belegt, wird wie bei Konflikten durchnummeriert.
            var targetPath = move.targetPath
            var suffix = 0
            while fileManager.fileExists(atPath: targetPath) {
                suffix += 1
                targetPath = directory + "/" + ExportSorter.renamed(name, suffix)
            }
            remember((move.sourcePath as NSString).deletingLastPathComponent)
            remember(directory)
            let dates = FileDates.read(move.source)
            do {
                try moveItem(atPath: move.sourcePath, toPath: targetPath)
            } catch {
                outcome.failures.append("\(move.relativeSource): \(error.localizedDescription)")
                continue
            }
            // Im neuen Ordner zeigt „Hinzugefügt“ sonst „jetzt“ (auf einem anderen Laufwerk auch „Erstellt“) – wie in A lassen.
            FileDates.write(dates, toPath: targetPath)
            outcome.moved.append(.init(sourcePath: move.sourcePath, targetPath: targetPath, dates: dates))
        }
        return outcome
    }

    /// Verschiebt alles zurück nach A, entfernt neu angelegte und wieder leere Ordner in B und setzt die Änderungsdaten
    /// der Ordner zurück. Gibt die Dateien zurück, bei denen das nicht ging.
    static func undo(_ outcome: Outcome) -> [String] {
        var failures: [String] = []
        for moved in outcome.moved.reversed() {
            do {
                try moveItem(atPath: moved.targetPath, toPath: moved.sourcePath)
                FileDates.write(moved.dates, toPath: moved.sourcePath)
            } catch {
                failures.append("\((moved.sourcePath as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        for directory in outcome.createdDirectories.reversed() { rmdir(directory) }
        for (folder, date) in outcome.folderDates {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder)
        }
        return failures
    }

    /// Verschiebt, ohne zu überschreiben: auf demselben Laufwerk durch Umbenennen (sofort), sonst als Kopie samt
    /// Metadaten, nach der das Original gelöscht wird. Pfade als Text, damit Namen Byte für Byte bleiben.
    private static func moveItem(atPath source: String, toPath target: String) throws {
        func failure(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        if renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == EXDEV else { throw failure(code) }
        guard copyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL)) == 0 else {
            let code = errno
            // Halb geschriebene Kopie wieder weg – sie stammt sicher von uns (COPYFILE_EXCL).
            if code != EEXIST { unlink(target) }
            throw failure(code)
        }
        // Erst löschen, wenn die Kopie vollständig ist.
        var sourceInfo = stat()
        var targetInfo = stat()
        guard stat(source, &sourceInfo) == 0, stat(target, &targetInfo) == 0, sourceInfo.st_size == targetInfo.st_size else {
            unlink(target)
            throw failure(EIO)
        }
        guard unlink(source) == 0 else {
            let code = errno
            unlink(target)
            throw failure(code)
        }
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let volumeA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let volumeB = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        return volumeA != nil && volumeA?.isEqual(volumeB) == true
    }

    /// Auf ein anderes Laufwerk wird kopiert – das muss in den freien Platz passen.
    private static func checkSpace(for plan: Plan, destination: URL) throws {
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // Externe Laufwerke melden „für wichtige Daten“ teils nichts – dann zählt der einfache freie Platz.
        let available = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
        guard available > 0 else { return }
        if plan.moveBytes > available { throw SyncError.notEnoughSpace(needed: plan.moveBytes, available: available) }
    }
}
