import Foundation

/// Zustand der App: verknüpfter Ordner, Scan, gefundene Gruppen und Markierungen.
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case done
        case failed(String)
    }

    enum Change {
        case all
        case progress
        case marks
    }

    struct Snapshot {
        let groups: [DuplicateGroup]
        let catalog: ScanCatalog?
        let marked: Set<URL>
        let options: FindOptions
    }

    struct TrashRecord {
        let moves: [TrashMove]
        let bytes: Int64
        let snapshot: Snapshot
    }

    var onChange: ((Change) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var folder: URL?

    var includeSubfolders: Bool {
        didSet {
            guard includeSubfolders != oldValue else { return }
            defaults.set(includeSubfolders, forKey: Keys.subfolders)
            resetResults()
        }
    }

    /// RAW und JPEG gleichen Namens im selben Ordner gelten als ein Foto (Standard: an).
    var pairRawWithJPEG: Bool {
        didSet {
            guard pairRawWithJPEG != oldValue else { return }
            defaults.set(pairRawWithJPEG, forKey: Keys.rawPairs)
            resetResults()
        }
    }

    var options: FindOptions {
        didSet {
            guard options != oldValue else { return }
            saveOptions()
            optionsChanged()
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = ScanProgress(message: "")
    private(set) var groups: [DuplicateGroup] = []
    private(set) var marked: Set<URL> = []
    private(set) var lastTrash: TrashRecord?
    private(set) var isTrashing = false
    private(set) var catalog: ScanCatalog?

    private var scanTask: Task<Void, Never>?
    private var regroupTask: Task<Void, Never>?
    private var scanID = 0
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let folder = "folderPath"
        static let subfolders = "includeSubfolders"
        static let rawPairs = "pairRawWithJPEG"
        static let identical = "findIdentical"
        static let compressed = "findCompressed"
        static let motif = "findMotif"
        static let minimumMotifSize = "minimumMotifSize"
        static let tolerance = "tolerance"
    }

    init() {
        if let path = defaults.string(forKey: Keys.folder), FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
        includeSubfolders = defaults.object(forKey: Keys.subfolders) as? Bool ?? true
        pairRawWithJPEG = defaults.object(forKey: Keys.rawPairs) as? Bool ?? true
        var options = FindOptions()
        options.identical = defaults.object(forKey: Keys.identical) as? Bool ?? options.identical
        options.compressed = defaults.object(forKey: Keys.compressed) as? Bool ?? options.compressed
        options.motif = defaults.object(forKey: Keys.motif) as? Bool ?? options.motif
        options.minimumMotifSize = max(2, defaults.object(forKey: Keys.minimumMotifSize) as? Int ?? options.minimumMotifSize)
        options.tolerance = defaults.object(forKey: Keys.tolerance) as? Int ?? options.tolerance
        self.options = options
    }

    private func saveOptions() {
        defaults.set(options.identical, forKey: Keys.identical)
        defaults.set(options.compressed, forKey: Keys.compressed)
        defaults.set(options.motif, forKey: Keys.motif)
        defaults.set(options.minimumMotifSize, forKey: Keys.minimumMotifSize)
        defaults.set(options.tolerance, forKey: Keys.tolerance)
    }

    // MARK: - Abgeleitete Werte

    var scannedCount: Int { catalog?.scannedCount ?? 0 }
    var markedFiles: [PhotoFile] { groups.flatMap(\.files).filter { marked.contains($0.url) } }
    var markedBytes: Int64 { markedFiles.reduce(0) { $0 + $1.totalSize } }
    var markedCompanionCount: Int { markedFiles.reduce(0) { $0 + $1.companions.count } }
    var duplicateCount: Int { groups.reduce(0) { $0 + $1.duplicateCount } }
    var suggestedBytes: Int64 { groups.reduce(0) { $0 + $1.suggestedBytes } }

    func isFullyMarked(_ group: DuplicateGroup) -> Bool { group.files.allSatisfy { marked.contains($0.url) } }
    var fullyMarkedGroupCount: Int { groups.filter(isFullyMarked).count }

    // MARK: - Ordner & Scan

    func setFolder(_ url: URL) {
        folder = url.standardizedFileURL
        defaults.set(folder?.path, forKey: Keys.folder)
        resetResults()
    }

    func startScan() {
        guard let folder, phase != .scanning, !options.isEmpty else { return }
        scanTask?.cancel()
        regroupTask?.cancel()
        scanID += 1
        let id = scanID
        groups = []
        marked = []
        catalog = nil
        lastTrash = nil
        phase = .scanning
        progress = ScanProgress(message: "Suche Bilder …")
        onChange?(.all)

        let recursive = includeSubfolders, pairRaw = pairRawWithJPEG, options = options, cache = ScanCache.shared
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in self?.updateProgress(progress, scanID: id) }
        }
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<(ScanCatalog, [DuplicateGroup]), Error>
            do {
                var catalog = try await PhotoScanner.scan(folder: folder, recursive: recursive,
                                                          pairRawWithJPEG: pairRaw, analyzeImages: options.needsImageAnalysis,
                                                          cache: cache, progress: report)
                let result = try await DuplicateFinder.groupsAnalyzingShots(in: catalog, options: options, cache: cache, progress: report)
                catalog.shots = result.shots
                outcome = .success((catalog, result.groups))
            } catch {
                outcome = .failure(error)
            }
            await self?.scanEnded(outcome, scanID: id)
            // Auch nach einem Abbruch: Was bis dahin analysiert wurde, muss beim nächsten Mal nicht erneut gelesen werden.
            cache.save()
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        scanTask?.cancel()
        scanID += 1
        phase = .idle
        onChange?(.all)
    }

    private func updateProgress(_ newProgress: ScanProgress, scanID id: Int) {
        guard id == scanID, phase == .scanning else { return }
        // Fortschrittsmeldungen können in leicht vertauschter Reihenfolge ankommen.
        if newProgress.message == progress.message, newProgress.done < progress.done { return }
        progress = newProgress
        onChange?(.progress)
    }

    private func scanEnded(_ outcome: Result<(ScanCatalog, [DuplicateGroup]), Error>, scanID id: Int) {
        guard id == scanID else { return }
        switch outcome {
        case .success(let (catalog, groups)):
            self.catalog = catalog
            apply(groups)
            phase = .done
        case .failure(let error):
            phase = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
        onChange?(.all)
    }

    private func resetResults() {
        scanTask?.cancel()
        regroupTask?.cancel()
        scanID += 1
        phase = .idle
        groups = []
        marked = []
        catalog = nil
        lastTrash = nil
        onChange?(.all)
    }

    /// Sortiert die Gruppen (größte Ersparnis zuerst) und übernimmt die Vorschläge als Markierungen.
    private func apply(_ newGroups: [DuplicateGroup]) {
        groups = newGroups.sorted { a, b in
            a.suggestedBytes != b.suggestedBytes ? a.suggestedBytes > b.suggestedBytes : a.files[0].url.path < b.files[0].url.path
        }
        marked = Set(groups.flatMap(\.suggestedMarks))
    }

    /// Neue Optionen: Wenn der letzte Scan alle nötigen Daten hat, nur neu gruppieren – sonst neu scannen lassen.
    private func optionsChanged() {
        guard phase == .done, let catalog else {
            onChange?(.all)
            return
        }
        if options.isEmpty || (options.needsImageAnalysis && catalog.fingerprints == nil) {
            resetResults()
            return
        }
        regroupTask?.cancel()
        let options = options
        regroupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                let cache = ScanCache.shared
                defer { cache.save() }
                return try? await DuplicateFinder.groupsAnalyzingShots(in: catalog, options: options, cache: cache) { _ in }
            }.value
            guard !Task.isCancelled, let self, let result else { return }
            self.catalog?.shots.merge(result.shots) { _, new in new }
            self.apply(result.groups)
            self.onChange?(.all)
        }
        onChange?(.all)
    }

    /// Vergisst alle gespeicherten Analysen; der nächste Scan liest wieder jedes Bild.
    func clearScanCache() {
        guard phase != .scanning else { return }
        Task.detached(priority: .utility) { ScanCache.shared.clear() }
    }

    // MARK: - Markieren

    func toggle(_ url: URL) {
        if marked.contains(url) { marked.remove(url) } else { marked.insert(url) }
        onChange?(.marks)
    }

    func applySuggestions() {
        marked = Set(groups.flatMap(\.suggestedMarks))
        onChange?(.marks)
    }

    func clearMarks() {
        marked = []
        onChange?(.marks)
    }

    func applySuggestion(group index: Int) {
        guard groups.indices.contains(index) else { return }
        let group = groups[index]
        group.files.forEach { marked.remove($0.url) }
        marked.formUnion(group.suggestedMarks)
        onChange?(.marks)
    }

    func keepAll(group index: Int) {
        guard groups.indices.contains(index) else { return }
        groups[index].files.forEach { marked.remove($0.url) }
        onChange?(.marks)
    }

    /// Behält in jeder Kopien-Gruppe die beste Datei aus diesem Ordner und markiert alle anderen.
    func prefer(folder: URL) {
        for group in groups where group.kind == .copies {
            guard let keep = group.files.first(where: { isInside(folder, $0.url) }) else { continue }
            for file in group.files {
                if file.url == keep.url { marked.remove(file.url) } else { marked.insert(file.url) }
            }
        }
        onChange?(.marks)
    }

    /// Markiert in jeder Kopien-Gruppe alle Dateien in diesem Ordner, sofern es außerhalb eine Kopie gibt –
    /// die beste davon bleibt erhalten.
    func markDuplicates(inFolder folder: URL) {
        for group in groups where group.kind == .copies {
            guard let keep = group.files.first(where: { !isInside(folder, $0.url) }) else { continue }
            marked.remove(keep.url)
            group.files.filter { isInside(folder, $0.url) }.forEach { marked.insert($0.url) }
        }
        onChange?(.marks)
    }

    private func isInside(_ folder: URL, _ file: URL) -> Bool {
        file.path.hasPrefix(folder.path.hasSuffix("/") ? folder.path : folder.path + "/")
    }

    // MARK: - Papierkorb

    func trashMarked() {
        let targets = markedFiles
        guard !targets.isEmpty, !isTrashing else { return }
        isTrashing = true
        onChange?(.marks)
        let snapshot = Snapshot(groups: groups, catalog: catalog, marked: marked, options: options)
        Task { [weak self] in
            let urls = targets.flatMap { [$0.url] + $0.companions }
            let outcome = await Task.detached(priority: .userInitiated) { FileTrash.moveToTrash(urls) }.value
            self?.trashFinished(outcome, targets: targets, snapshot: snapshot)
        }
    }

    private func trashFinished(_ outcome: FileTrash.Outcome, targets: [PhotoFile], snapshot: Snapshot) {
        isTrashing = false
        let moved = Set(outcome.moved.map(\.original))
        if !moved.isEmpty {
            let bytes = targets.filter { moved.contains($0.url) }.reduce(0) { $0 + $1.totalSize }
            lastTrash = TrashRecord(moves: outcome.moved, bytes: bytes, snapshot: snapshot)
            remove(moved)
        }
        onChange?(.all)
        if !outcome.failed.isEmpty {
            onError?("\(plural(outcome.failed.count, "Datei konnte", "Dateien konnten")) nicht in den Papierkorb verschoben werden:\n\n"
                     + outcome.failed.prefix(8).joined(separator: "\n"))
        }
    }

    func undoTrash() {
        guard let record = lastTrash, !isTrashing else { return }
        lastTrash = nil
        var notRestored = Set<URL>()
        for move in record.moves {
            do {
                try FileManager.default.moveItem(at: move.trashed, to: move.original)
            } catch {
                notRestored.insert(move.original)
            }
        }
        groups = record.snapshot.groups
        catalog = record.snapshot.catalog
        marked = record.snapshot.marked
        if !notRestored.isEmpty { remove(notRestored) }
        if record.snapshot.options != options { optionsChanged() } else { onChange?(.all) }
        if !notRestored.isEmpty {
            onError?("\(plural(notRestored.count, "Datei konnte", "Dateien konnten")) nicht wiederhergestellt werden. Sie liegen weiterhin im Papierkorb.")
        }
    }

    private func remove(_ urls: Set<URL>) {
        marked.subtract(urls)
        catalog = catalog?.removing(urls)
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { urls.contains($0.url) }
            group.suggestedMarks.subtract(urls)
            return group.files.count > 1 ? group : nil
        }
    }
}
