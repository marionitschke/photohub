import Foundation

/// Scan ohne Fenster, z. B. `PhotoHub --scan ~/Bilder --identical --compressed --motif 3 --tolerance 10`.
/// Ohne Auswahl wird nach allem gesucht. Nutzt denselben Scan-Cache wie die App, außer mit
/// `--cache <Datei>` oder `--no-cache`. Gibt nur aus, löscht nichts.
enum CommandLineScan {
    static func run(_ args: [String]) -> Never {
        guard let path = args.first, !path.hasPrefix("--") else {
            print("Aufruf: PhotoHub --scan <Ordner> [--identical] [--compressed] [--motif N] [--tolerance N] [--flat] [--no-raw-pairs] [--distances] [--cache <Datei> | --no-cache]")
            exit(2)
        }
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func intValue(after flag: String) -> Int? { value(after: flag).flatMap { Int($0) } }
        var options = FindOptions()
        if args.contains("--identical") || args.contains("--compressed") || args.contains("--motif") {
            options.identical = args.contains("--identical")
            options.compressed = args.contains("--compressed")
            options.motif = args.contains("--motif")
        }
        options.minimumMotifSize = intValue(after: "--motif") ?? options.minimumMotifSize
        options.tolerance = intValue(after: "--tolerance") ?? options.tolerance
        let recursive = !args.contains("--flat")
        let pairRaw = !args.contains("--no-raw-pairs")
        let showDistances = args.contains("--distances")
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let cache = cache(from: args)

        Task.detached {
            do {
                let start = Date()
                let catalog = try await PhotoScanner.scan(folder: folder, recursive: recursive,
                                                          pairRawWithJPEG: pairRaw,
                                                          analyzeImages: options.needsImageAnalysis || showDistances,
                                                          cache: cache) { _ in }
                let result = try await DuplicateFinder.groupsAnalyzingShots(in: catalog, options: options, cache: cache) { _ in }
                cache.save()
                let groups = result.groups.sorted { $0.files[0].url.path < $1.files[0].url.path }
                print("\(plural(catalog.scannedCount, "Bild", "Bilder")) durchsucht, \(plural(groups.count, "Gruppe", "Gruppen")) gefunden (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
                for (index, group) in groups.enumerated() {
                    print("\nGruppe \(index + 1): \(group.title)")
                    for file in group.files {
                        let tag = group.suggestedMarks.contains(file.url) ? "löschen " : "behalten"
                        var role = group.roles[file.url].map(roleName) ?? ""
                        if group.kind == .motif, let shot = result.shots[file.url] {
                            if let sharpness = shot.sharpness { role += String(format: " · Schärfe %.2f", sharpness) }
                            if group.blurry.contains(file.url) { role += " · unscharf" }
                            if shot.faceCount > 0 {
                                role += " · \(plural(shot.faceCount, "Gesicht", "Gesichter"))"
                                if let quality = shot.quality { role += String(format: ", Qualität %.2f", quality) }
                                if shot.hasClosedEyes { role += " · Augen zu" }
                            }
                        }
                        if let companions = file.companionSummary { role += "  \(companions)" }
                        let info = [file.size.formattedBytes, file.dimensionsText].compactMap { $0 }.joined(separator: ", ")
                        print("  [\(tag)] \(file.url.path)  (\(info))  \(role)")
                    }
                }
                if showDistances { printNearestDistances(catalog.fingerprints ?? []) }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// `--no-cache` → ohne, `--cache <Datei>` → eigene Datei, sonst der Cache der App.
    static func cache(from args: [String]) -> ScanCache {
        if args.contains("--no-cache") { return ScanCache(fileURL: nil) }
        if let index = args.firstIndex(of: "--cache"), args.indices.contains(index + 1) {
            return ScanCache(fileURL: URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath))
        }
        return .shared
    }

    private static func roleName(_ role: PhotoRole) -> String {
        switch role {
        case .best: return "bestes"
        case .identicalCopy: return "bytegleich"
        case .compressed: return "komprimiert"
        case .sameMotif: return "gleiches Motiv"
        }
    }

    /// Hilfe zum Kalibrieren der Toleranz: Abstand jedes Bildes zu seinem ähnlichsten Nachbarn.
    private static func printNearestDistances(_ prints: [Fingerprint]) {
        print("\nNächster Nachbar je Bild (Abstand von 128 Bit):")
        for (i, a) in prints.enumerated() {
            var best = (distance: Int.max, name: "")
            for (j, b) in prints.enumerated() where i != j {
                let d = (a.horizontal ^ b.horizontal).nonzeroBitCount + (a.vertical ^ b.vertical).nonzeroBitCount
                if d < best.distance { best = (d, b.file.url.lastPathComponent) }
            }
            print(String(format: "%4d  %@  ↔  %@", best.distance, a.file.url.lastPathComponent, best.name))
        }
    }
}

/// Apple Fotos Export ohne Fenster: `PhotoHub --sort <Export-Ordner> <Ziel> [--apply] [--keep-dates]`.
/// Ohne `--apply` nur Vorschau. Kopiert, der Export bleibt unverändert.
enum CommandLineSort {
    static func run(_ args: [String]) -> Never {
        let paths = args.filter { !$0.hasPrefix("--") }
        guard paths.count == 2 else {
            print("Aufruf: PhotoHub --sort <Export-Ordner> <Ziel> [--apply] [--keep-dates]")
            exit(2)
        }
        let source = URL(fileURLWithPath: (paths[0] as NSString).expandingTildeInPath, isDirectory: true)
        let destination = URL(fileURLWithPath: (paths[1] as NSString).expandingTildeInPath, isDirectory: true)
        let apply = args.contains("--apply")
        let setDates = !args.contains("--keep-dates")

        Task.detached {
            do {
                let plan = try ExportSorter.plan(source: source, destination: destination)
                print("Modus:  \(apply ? "AUSFÜHRUNG" : "VORSCHAU (keine Änderungen)")")
                print("Quelle: \(source.path)\nZiel:   \(destination.path)\n")
                for folder in plan.folders {
                    print("\(folder.source.lastPathComponent) -> \(folder.targetName) (\(plural(folder.copies.count + folder.alreadyCopied.count, "Datei", "Dateien")))")
                    for file in folder.alreadyCopied { print("    Schon im Ziel: \(file.lastPathComponent)") }
                    for copy in folder.copies where copy.isRenamed {
                        print("    Namenskonflikt: \(copy.source.lastPathComponent) -> \(copy.target.lastPathComponent)")
                    }
                }
                for folder in plan.unrecognized { print("Nicht erkannt, bleibt liegen: \(folder.lastPathComponent)") }
                print("\nOrdner: \(plan.folders.count), Dateien: \(plan.fileCount), kopieren: \(plan.copyCount) "
                      + "(umbenannt: \(plan.renameCount)), schon im Ziel: \(plan.alreadyCopiedCount), nicht erkannt: \(plan.unrecognized.count)")
                if apply {
                    let outcome = try await ExportSorter.apply(source: source, destination: destination, setCaptureDates: setDates) { _ in }
                    print("Kopiert: \(outcome.copied.count) (umbenannt: \(outcome.renamedCount)), schon im Ziel: \(outcome.alreadyCopiedCount), "
                          + "Aufnahmezeit gesetzt: \(outcome.datesSet), ohne Aufnahmezeit: \(outcome.datesMissing)")
                    for failure in outcome.failures { print("Fehler: \(failure)") }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}

/// Datum korrigieren ohne Fenster: `PhotoHub --fix-dates <Ordner> [--apply] [--flat]`. Ohne `--apply` nur Vorschau.
enum CommandLineFixDates {
    static func run(_ args: [String]) -> Never {
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            print("Aufruf: PhotoHub --fix-dates <Ordner> [--apply] [--flat]")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let apply = args.contains("--apply")
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        func text(_ date: Date?) -> String { date.map(formatter.string) ?? "–" }

        Task.detached {
            do {
                let plan = try await DateFixer.plan(folder: folder, recursive: !args.contains("--flat")) { _ in }
                for item in plan.toFix {
                    let relative = item.path.hasPrefix(folder.path + "/") ? String(item.path.dropFirst(folder.path.count + 1)) : item.path
                    print("\(relative): Aufnahme \(text(item.captureDate)) | Erstellt \(text(item.current.created)), "
                          + "Geändert \(text(item.current.modified)), Hinzugefügt \(text(item.current.added))")
                }
                print("Geprüft: \(plan.checkedCount), zu korrigieren: \(plan.toFix.count), stimmen schon: \(plan.correctCount), "
                      + "ohne Aufnahmezeit: \(plan.withoutDate.count), nur in iCloud: \(plan.notDownloadedCount)")
                if apply {
                    let outcome = DateFixer.apply(plan) { _ in }
                    print("Korrigiert: \(outcome.changed.count), Fehler: \(outcome.failures.count)")
                    for failure in outcome.failures { print("Fehler: \(failure)") }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}

/// Bilder-Ordner abgleichen ohne Fenster: `PhotoHub --sync <A> <B> [--apply] [--cache <Datei> | --no-cache]`.
/// Ohne `--apply` nur Vorschau, mit `--apply` wandern die in B fehlenden Fotos und Videos aus A nach B.
enum CommandLineSync {
    static func run(_ args: [String]) -> Never {
        let cacheIndex = args.firstIndex(of: "--cache")
        let paths = args.indices.filter { !args[$0].hasPrefix("--") && $0 != cacheIndex.map { $0 + 1 } }.map { args[$0] }
        guard paths.count == 2 else {
            print("Aufruf: PhotoHub --sync <A> <B> [--apply] [--cache <Datei> | --no-cache]")
            exit(2)
        }
        let source = URL(fileURLWithPath: (paths[0] as NSString).expandingTildeInPath, isDirectory: true)
        let destination = URL(fileURLWithPath: (paths[1] as NSString).expandingTildeInPath, isDirectory: true)
        let apply = args.contains("--apply")
        let cache = CommandLineScan.cache(from: args)

        Task.detached {
            do {
                let plan = try await FolderSync.plan(source: source, destination: destination, cache: cache) { _ in }
                cache.save()
                print("Modus: \(apply ? "AUSFÜHRUNG" : "VORSCHAU (keine Änderungen)")")
                print("A: \(source.path)\nB: \(destination.path)\n")
                for move in plan.moves {
                    print(move.isRenamed ? "\(move.relativeSource) -> \(move.relativeTarget)" : move.relativeSource)
                }
                print("\nGeprüft: \(plan.checkedCount), fehlen in B: \(plan.moves.count) (\(plan.moveBytes.formattedBytes), umbenannt: \(plan.renameCount)), "
                      + "schon in B: \(plan.presentCount), doppelt in A: \(plan.duplicateCount), "
                      + "nur in iCloud: A \(plan.notDownloadedInSource) / B \(plan.notDownloadedInDestination), "
                      + "andere Dateien in A: \(plan.otherFileCount)\(plan.acrossVolumes ? ", anderes Laufwerk" : "")")
                if apply {
                    let outcome = try FolderSync.apply(plan, source: source, destination: destination) { _ in }
                    print("Verschoben: \(outcome.moved.count), Ordner angelegt: \(outcome.createdDirectories.count), Fehler: \(outcome.failures.count)")
                    for failure in outcome.failures { print("Fehler: \(failure)") }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
