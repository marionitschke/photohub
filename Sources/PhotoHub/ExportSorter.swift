import Foundation

/// Kopiert aus Apple Fotos exportierte Tagesordner („1. August 2026“) in eine Jahr/Monat-Struktur
/// (`Ziel/2026/08`). Vorbild ist das Skript `organize_photos.py`, das verschiebt; hier bleibt der Export
/// standardmäßig unverändert, damit sich alles jederzeit neu machen lässt. Auf Wunsch wird wie im Skript
/// verschoben, leer gewordene Tagesordner verschwinden. Außerdem:
/// - Schon kopierte Dateien werden erkannt (gleicher Name, gleicher Inhalt) – auch unter `Name_1`.
/// - Dateien gleichen Namens (Live Photo: HEIC + MOV) bekommen bei Konflikten denselben Zusatz `_1`.
/// - Die Aufnahmezeit wird ohne exiftool gelesen (`CaptureDate`: ImageIO bzw. AVFoundation, mit Zeitzone).
/// - Rückgängig legt die Kopien in den Papierkorb bzw. verschiebt alles zurück in den Export.
enum ExportSorter {
    struct Plan: Sendable {
        var folders: [FolderPlan] = []
        /// Unterordner, deren Name kein Datum ist – sie bleiben unangetastet.
        var unrecognized: [URL] = []

        var fileCount: Int { folders.reduce(0) { $0 + $1.copies.count + $1.alreadyCopied.count } }
        var copyCount: Int { folders.reduce(0) { $0 + $1.copies.count } }
        var copyBytes: Int64 { folders.reduce(0) { $0 + $1.copies.reduce(0) { $0 + $1.size } } }
        var renameCount: Int { folders.reduce(0) { $0 + $1.renamedCount } }
        var alreadyCopiedCount: Int { folders.reduce(0) { $0 + $1.alreadyCopied.count } }
        var isEmpty: Bool { folders.isEmpty && unrecognized.isEmpty }
    }

    struct FolderPlan: Sendable {
        let source: URL
        let year: Int
        let month: Int
        let day: Int
        let target: URL
        var copies: [Copy] = []
        /// Liegen mit gleichem Namen (ggf. `_1` …) und Inhalt schon im Ziel – werden übersprungen.
        var alreadyCopied: [URL] = []

        var targetName: String { String(format: "%04d/%02d", year, month) }
        var renamedCount: Int { copies.filter(\.isRenamed).count }
    }

    struct Copy: Sendable {
        let source: URL
        /// Als Text statt URL: `URL` speichert Umlaute zerlegt (NFD), der Name soll aber Byte für Byte bleiben.
        let targetPath: String
        let size: Int64
        var target: URL { URL(fileURLWithPath: targetPath) }
        var isRenamed: Bool { exactName(source) != (targetPath as NSString).lastPathComponent }
    }

    /// Was beim Kopieren bzw. Verschieben entstanden ist – genug, um es zurückzunehmen.
    struct Outcome: Sendable {
        struct Move: Sendable {
            let sourcePath: String
            let targetPath: String
            /// Daten im Export vorher – `undo` stellt sie wieder her.
            let dates: FileDates
        }
        var movesFiles = false
        /// Die neuen Dateien im Ziel.
        var transferred: [URL] = []
        /// Nur beim Verschieben: woher jede Datei kam.
        var moved: [Move] = []
        struct RemovedFolder: Sendable {
            let path: String
            let dates: FileDates
        }
        /// Beim Verschieben geleerte und deshalb entfernte Tagesordner im Export – mit ihren Daten für `undo`.
        var removedFolders: [RemovedFolder] = []
        var createdDirectories: [URL] = []
        /// Änderungsdatum der berührten Ordner vorher – neue und entfernte Dateien ändern es.
        var folderDates: [URL: Date] = [:]
        var renamedCount = 0
        var alreadyCopiedCount = 0
        var datesSet = 0
        var datesMissing = 0
        var failures: [String] = []
        var wasCancelled = false
    }

    enum SortError: LocalizedError {
        case destinationInsideExport(String)
        case notEnoughSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .destinationInsideExport(let folder):
                return "Der Zielordner liegt im Tagesordner „\(folder)“ des Exports. Wähle einen Zielordner außerhalb davon."
            case .notEnoughSpace(let needed, let available):
                return "Im Ziel ist nicht genug Platz: Die Kopien brauchen \(needed.formattedBytes), frei sind \(available.formattedBytes)."
            }
        }
    }

    // MARK: - Ordnernamen

    private static let months = [
        "januar": 1, "februar": 2, "märz": 3, "maerz": 3, "april": 4, "mai": 5, "juni": 6,
        "juli": 7, "august": 8, "september": 9, "oktober": 10, "november": 11, "dezember": 12,
    ]
    private static let folderPattern = try! NSRegularExpression(pattern: #"^\s*(\d{1,2})\.\s+([A-Za-zÄÖÜäöüß]+)\s+(\d{4})\s*$"#)
    private static let ignoredFiles: Set<String> = [".DS_Store"]

    /// „1. August 2026“ → 2026, 8, 1. Wie im Skript nur deutsche Monatsnamen.
    static func parseDateFolder(_ name: String) -> (year: Int, month: Int, day: Int)? {
        // Umlaute können zerlegt gespeichert sein („a“ + Trema) – vor dem Vergleich zusammensetzen.
        let name = name.precomposedStringWithCanonicalMapping
        let range = NSRange(name.startIndex..., in: name)
        guard let match = folderPattern.firstMatch(in: name, range: range),
              let day = Range(match.range(at: 1), in: name).flatMap({ Int(name[$0]) }),
              let monthName = Range(match.range(at: 2), in: name).map({ name[$0].lowercased() }),
              let month = months[monthName],
              let year = Range(match.range(at: 3), in: name).flatMap({ Int(name[$0]) }) else { return nil }
        return (year, month, day)
    }

    // MARK: - Vorschau

    /// Plant das Kopieren, ohne etwas zu verändern.
    static func plan(source: URL, destination: URL) throws -> Plan {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var plan = Plan()
        var dated: [(url: URL, date: (year: Int, month: Int, day: Int))] = []
        for url in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let date = parseDateFolder(url.lastPathComponent) {
                dated.append((url, date))
            } else {
                plan.unrecognized.append(url)
            }
        }
        let destinationPath = destination.standardizedFileURL.path + "/"
        if let folder = dated.first(where: { destinationPath.hasPrefix($0.url.standardizedFileURL.path + "/") }) {
            throw SortError.destinationInsideExport(folder.url.lastPathComponent)
        }
        dated.sort { ($0.date.year, $0.date.month, $0.date.day, $0.url.lastPathComponent) < ($1.date.year, $1.date.month, $1.date.day, $1.url.lastPathComponent) }
        plan.unrecognized.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        // Ziele, die dieser Lauf schon vergibt (ohne Groß-/Kleinschreibung, wie APFS) → Quelldatei.
        var claimed: [String: URL] = [:]
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        enum Slot { case free, same, taken }
        func slot(for file: URL, at path: String) -> Slot {
            if let other = claimed[key(path)] { return sameContent(file, other) ? .same : .taken }
            guard fileManager.fileExists(atPath: path) else { return .free }
            return sameContent(file, URL(fileURLWithPath: path)) ? .same : .taken
        }

        for (folder, date) in dated {
            if Task.isCancelled { throw CancellationError() }
            let target = destination.appendingPathComponent(String(format: "%04d", date.year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", date.month), isDirectory: true)
            var folderPlan = FolderPlan(source: folder, year: date.year, month: date.month, day: date.day, target: target)
            let files = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && !ignoredFiles.contains($0.lastPathComponent) }
            // Gleicher Name, andere Endung (Live Photo, RAW+JPEG, .AAE) landet gemeinsam unter einem Namen:
            // dem ersten – „IMG_1“, „IMG_1_1“, … –, unter dem keine Datei mit anderem Inhalt liegt. Was dort
            // schon inhaltsgleich liegt, stammt aus einem früheren Lauf und wird übersprungen.
            let groups = Dictionary(grouping: files) { $0.deletingPathExtension().lastPathComponent.lowercased() }
            for stem in groups.keys.sorted() {
                let members = groups[stem]!.sorted { $0.lastPathComponent < $1.lastPathComponent }
                func path(_ file: URL, _ suffix: Int) -> String { target.path + "/" + renamed(exactName(file), suffix) }
                var suffix = 0
                var slots: [Slot] = []
                while true {
                    slots = members.map { slot(for: $0, at: path($0, suffix)) }
                    if !slots.contains(.taken) { break }
                    suffix += 1
                }
                for (file, slot) in zip(members, slots) {
                    if slot == .same {
                        folderPlan.alreadyCopied.append(file)
                        continue
                    }
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    let copy = Copy(source: file, targetPath: path(file, suffix), size: size)
                    claimed[key(copy.targetPath)] = file
                    folderPlan.copies.append(copy)
                }
            }
            folderPlan.copies.sort { $0.source.lastPathComponent.localizedStandardCompare($1.source.lastPathComponent) == .orderedAscending }
            if !folderPlan.copies.isEmpty || !folderPlan.alreadyCopied.isEmpty { plan.folders.append(folderPlan) }
        }
        return plan
    }

    /// Dateiname wie auf der Platte gespeichert (`URL.lastPathComponent` kann Umlaute zerlegen).
    fileprivate static func exactName(_ url: URL) -> String { (url.path as NSString).lastPathComponent }

    /// „IMG_1.HEIC“ → „IMG_1_2.HEIC“ (wie im Skript); 0 = unverändert.
    static func renamed(_ name: String, _ suffix: Int) -> String {
        guard suffix > 0 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
    }

    /// Gleiche Größe und gleiche ersten und letzten 64 KB. Liest pro Datei höchstens 128 KB – die Vorschau läuft
    /// bei jedem Wechsel in den Tab, auch über große Videos. Verschiedene Aufnahmen unterscheiden sich schon in
    /// den Metadaten am Anfang; ein Irrtum hieße nur, dass eine Datei nicht kopiert wird – der Export bleibt ja.
    private static func sameContent(_ a: URL, _ b: URL) -> Bool {
        let sizeA = (try? a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let sizeB = (try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let sizeA, sizeA == sizeB, let edgesA = edges(of: a, size: sizeA), let edgesB = edges(of: b, size: sizeA) else { return false }
        return edgesA == edgesB
    }

    private static func edges(of url: URL, size: Int) -> Data? {
        let chunk = 64 * 1024
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard size > 2 * chunk else { return try? handle.readToEnd() ?? Data() }
        guard var data = try? handle.read(upToCount: chunk), (try? handle.seek(toOffset: UInt64(size - chunk))) != nil,
              let tail = try? handle.read(upToCount: chunk) else { return nil }
        data.append(tail)
        return data
    }

    // MARK: - Kopieren

    /// Plant neu (falls sich seit der Vorschau etwas geändert hat) und kopiert bzw. verschiebt. Bei Abbruch bleibt es
    /// beim bis dahin Erledigten – auch das lässt sich mit `undo` zurücknehmen.
    static func apply(source: URL, destination: URL, setCaptureDates: Bool, moveFiles: Bool,
                      progress: @escaping PhotoScanner.ProgressHandler) async throws -> Outcome {
        let fileManager = FileManager.default
        let plan = try plan(source: source, destination: destination)
        try checkSpace(for: plan, source: source, destination: destination, moveFiles: moveFiles)
        var outcome = Outcome()
        outcome.movesFiles = moveFiles
        outcome.alreadyCopiedCount = plan.alreadyCopiedCount
        let total = plan.copyCount
        let message = moveFiles ? "Verschiebe …" : "Kopiere …"
        var done = 0
        progress(ScanProgress(message: message, done: 0, total: total))

        func remember(_ folder: URL) {
            guard outcome.folderDates[folder] == nil,
                  let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return }
            outcome.folderDates[folder] = date
        }
        remember(destination)
        if moveFiles { remember(source) }

        folders: for folder in plan.folders where !folder.copies.isEmpty {
            for directory in [folder.target.deletingLastPathComponent(), folder.target] { remember(directory) }
            if moveFiles { remember(folder.source) }
            for directory in [folder.target.deletingLastPathComponent(), folder.target] where !fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    outcome.createdDirectories.append(directory)
                } catch {
                    outcome.failures.append("\(directory.path): \(error.localizedDescription)")
                    continue folders
                }
            }
            for copy in folder.copies {
                if Task.isCancelled {
                    outcome.wasCancelled = true
                    break folders
                }
                // Ist das Ziel inzwischen belegt, wird wie bei Konflikten durchnummeriert.
                let directory = (copy.targetPath as NSString).deletingLastPathComponent
                let name = (copy.targetPath as NSString).lastPathComponent
                var targetPath = copy.targetPath
                var suffix = 0
                while fileManager.fileExists(atPath: targetPath) {
                    suffix += 1
                    targetPath = directory + "/" + renamed(name, suffix)
                }
                let previous = moveFiles ? FileDates.read(copy.source) : nil
                do {
                    if moveFiles {
                        try FileMove.move(atPath: copy.source.path, toPath: targetPath)
                    } else {
                        try copyItem(copy.source, toPath: targetPath)
                    }
                } catch {
                    outcome.failures.append("\(copy.source.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                if let previous {
                    // Im neuen Ordner zeigt „Hinzugefügt“ sonst „jetzt“ – erst wie im Export, die Aufnahmezeit folgt ggf. unten.
                    FileDates.write(previous, toPath: targetPath)
                    outcome.moved.append(.init(sourcePath: copy.source.path, targetPath: targetPath, dates: previous))
                }
                let target = URL(fileURLWithPath: targetPath)
                outcome.transferred.append(target)
                if (targetPath as NSString).lastPathComponent != exactName(copy.source) { outcome.renamedCount += 1 }
                if setCaptureDates {
                    if let date = await CaptureDate.read(target) {
                        FileDates.write(.all(date), toPath: targetPath)
                        outcome.datesSet += 1
                    } else {
                        // Ohne Aufnahmezeit bleibt das Datum des Originals – „Hinzugefügt“ zieht mit, statt „jetzt“ zu zeigen.
                        if let modified = FileDates.read(target).modified { FileDates.write(FileDates(added: modified), toPath: targetPath) }
                        outcome.datesMissing += 1
                    }
                }
                done += 1
                if done % 20 == 0 || done == total { progress(ScanProgress(message: message, done: done, total: total)) }
            }
            // Wie im Skript: Ein leer gewordener Tagesordner verschwindet (`rmdir` scheitert, solange noch etwas darin liegt).
            if moveFiles {
                let dates = FileDates.read(folder.source)
                if rmdir(folder.source.path) == 0 { outcome.removedFolders.append(.init(path: folder.source.path, dates: dates)) }
            }
        }
        return outcome
    }

    /// Nimmt ein Kopieren zurück (Kopien in den Papierkorb) bzw. ein Verschieben (alles zurück in den Export, entfernte
    /// Tagesordner wieder angelegt). Danach verschwinden neu angelegte und wieder leere Zielordner, die Änderungsdaten
    /// der Ordner sind wie vorher. Gibt zurück, was nicht ging.
    static func undo(_ outcome: Outcome) -> [String] {
        let fileManager = FileManager.default
        var failures: [String] = []
        if outcome.movesFiles {
            for folder in outcome.removedFolders { mkdir(folder.path, 0o777) }
            for move in outcome.moved.reversed() {
                do {
                    try FileMove.move(atPath: move.targetPath, toPath: move.sourcePath)
                    FileDates.write(move.dates, toPath: move.sourcePath)
                } catch {
                    failures.append("\((move.sourcePath as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            // Erstellt und Hinzugefügt der wieder angelegten Ordner; das Änderungsdatum folgt unten aus `folderDates`.
            for folder in outcome.removedFolders { FileDates.write(folder.dates, toPath: folder.path) }
        } else {
            failures = FileTrash.moveToTrash(outcome.transferred.filter { fileManager.fileExists(atPath: $0.path) }).failed
        }
        for directory in outcome.createdDirectories.reversed() where (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: directory)
        }
        for (folder, date) in outcome.folderDates {
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
        }
        return failures
    }

    /// Kopiert wie `cp -c`: auf APFS als Klon (sofort, belegt keinen zusätzlichen Platz, bis sich eine Seite
    /// ändert), sonst vollständig, jeweils mit Zeitstempeln und Metadaten. Der Zielpfad ist Text, damit der Name
    /// Byte für Byte erhalten bleibt. Überschreibt nie.
    private static func copyItem(_ source: URL, toPath target: String) throws {
        guard copyfile(source.path, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_CLONE)) == 0 else {
            let code = errno
            // Halb geschriebene Kopie wieder weg – sie stammt sicher von uns (COPYFILE_EXCL).
            if code != EEXIST { try? FileManager.default.removeItem(atPath: target) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Auf einem anderen Laufwerk (beim Kopieren auch ohne Klon-Unterstützung) müssen die Dateien in den freien Platz passen.
    /// Verschieben auf demselben Laufwerk ist nur ein Umbenennen.
    private static func checkSpace(for plan: Plan, source: URL, destination: URL, moveFiles: Bool) throws {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let target = try? destination.resourceValues(forKeys: keys),
              let available = target.volumeAvailableCapacityForImportantUsage else { return }
        let sourceVolume = (try? source.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let sameVolume = sourceVolume != nil && (sourceVolume as? NSObject)?.isEqual(target.volumeIdentifier) == true
        guard !(sameVolume && (moveFiles || target.volumeSupportsFileCloning == true)) else { return }
        let needed = plan.copyBytes
        if needed > available { throw SortError.notEnoughSpace(needed: needed, available: available) }
    }
}
