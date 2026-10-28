import AppKit

/// Tab „Apple Fotos Export“: Tagesordner eines Apple-Fotos-Exports in eine Jahr/Monat-Struktur kopieren.
/// Unabhängig von der Duplikatsuche; nur „Ziel auf Duplikate prüfen“ übergibt den Zielordner dorthin.
final class SortViewController: NSViewController {
    enum Phase {
        case idle
        case planning
        case ready
        case applying
        case done(ExportSorter.Outcome)
        case failed(title: String, message: String)
    }

    /// Zeile der Vorschau-Tabelle.
    private enum Row {
        case folder(ExportSorter.FolderPlan)
        case unrecognized(URL)
    }

    var onFindDuplicates: ((URL) -> Void)?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let source = "sortSourcePath"
        static let destination = "sortDestinationPath"
        static let setsCaptureDates = "sortSetsCaptureDates"
    }

    private var source: URL?
    private var destination: URL?
    private var setsCaptureDates = true
    private var phase: Phase = .idle
    private var plan = ExportSorter.Plan()
    private var rows: [Row] = []
    private var lastOutcome: ExportSorter.Outcome?
    private var task: Task<Void, Never>?
    private var applyWork: Task<Result<ExportSorter.Outcome, Error>, Never>?
    private var runID = 0

    // Kopfzeile
    private lazy var sourceButton = pathButton(action: #selector(revealSource))
    private lazy var destinationButton = pathButton(action: #selector(revealDestination))
    private lazy var chooseSourceButton = NSButton(title: "Wählen …", target: self, action: #selector(chooseSource))
    private lazy var chooseDestinationButton = NSButton(title: "Wählen …", target: self, action: #selector(chooseDestination))
    private lazy var datesCheckbox = NSButton(checkboxWithTitle: "Dateidatum auf Aufnahmezeit setzen", target: self, action: #selector(datesChanged))
    private lazy var refreshButton = NSButton(title: "Vorschau aktualisieren", target: self, action: #selector(refresh))

    // Mitte
    private let messageView = MessageView()
    private let progressView = ScanProgressView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    // Fußzeile
    private let bottomSeparator = NSBox()
    private let bottomBar = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let undoLabel = NSTextField(labelWithString: "")
    private lazy var undoButton = NSButton(title: "Rückgängig", target: self, action: #selector(undo))
    private lazy var duplicatesButton = NSButton(title: "Ziel auf Duplikate prüfen", target: self, action: #selector(findDuplicates))
    private lazy var applyButton = NSButton(title: "Kopieren …", target: self, action: #selector(confirmApply))

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Apple Fotos Export"
        source = defaults.string(forKey: Keys.source).flatMap(Self.existingFolder)
        destination = defaults.string(forKey: Keys.destination).flatMap(Self.existingFolder)
        setsCaptureDates = defaults.object(forKey: Keys.setsCaptureDates) as? Bool ?? true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    private static func existingFolder(_ path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Aufbau

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
        root.onDropFolder = { [weak self] url in self?.setSource(url) }
        view = root

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        bottomSeparator.boxType = .separator

        let center = NSView()
        center.setContentHuggingPriority(.init(1), for: .vertical)
        center.setContentCompressionResistancePriority(.init(1), for: .vertical)
        for subview in [messageView, progressView, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            center.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: center.topAnchor),
                subview.bottomAnchor.constraint(equalTo: center.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: center.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            ])
        }

        let layout = NSStackView(views: [makeTopBar(), topSeparator, center, bottomSeparator, makeBottomBar()])
        layout.orientation = .vertical
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        for subview in layout.arrangedSubviews {
            subview.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }

        setUpTable()
        progressView.cancelButton.target = self
        progressView.cancelButton.action = #selector(cancel)
    }

    private func pathButton(action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.init(1), for: .horizontal)
        button.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return button
    }

    private func makeTopBar() -> NSView {
        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.textColor = .secondaryLabelColor
            return field
        }
        datesCheckbox.toolTip = "Setzt „Erstellt“, „Geändert“ und „Hinzugefügt“ jeder Kopie auf die Aufnahmezeit aus den Metadaten "
            + "(EXIF bzw. Video). Die Bilddaten und der Export bleiben unverändert."
        refreshButton.toolTip = "Export-Ordner und Ziel erneut prüfen"
        let options = NSStackView(views: [datesCheckbox, NSView(), refreshButton])
        options.views[1].setContentHuggingPriority(.init(1), for: .horizontal)

        let grid = NSGridView(views: [
            [label("Export aus Fotos:"), sourceButton, chooseSourceButton],
            [label("Ziel (Jahr/Monat):"), destinationButton, chooseDestinationButton],
            [NSGridCell.emptyContentView, options, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 10
        grid.rowSpacing = 8
        grid.row(at: 2).topPadding = 2

        let bar = NSStackView(views: [grid])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        grid.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -28).isActive = true
        return bar
    }

    private func makeBottomBar() -> NSView {
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(10), for: .horizontal)
        undoLabel.lineBreakMode = .byTruncatingTail
        undoLabel.setContentCompressionResistancePriority(.init(20), for: .horizontal)
        duplicatesButton.toolTip = "Wechselt zur Duplikatsuche und durchsucht den Zielordner"
        applyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        applyButton.imagePosition = .imageLeading
        applyButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bottomBar.setViews([summaryLabel, undoLabel, undoButton, spacer, duplicatesButton, applyButton], in: .leading)
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 10
        bottomBar.setCustomSpacing(16, after: summaryLabel)
        bottomBar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return bottomBar
    }

    private func setUpTable() {
        let columns: [(id: String, title: String, width: CGFloat, alignment: NSTextAlignment)] = [
            ("folder", "Export-Ordner", 250, .left),
            ("target", "Ziel", 90, .left),
            ("copies", "Kopieren", 90, .right),
            ("renamed", "davon umbenannt", 120, .right),
            ("present", "Schon im Ziel", 100, .right),
            ("note", "Hinweis", 300, .left),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 50
            column.headerCell.alignment = spec.alignment
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(revealRow)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.subtitle = source?.lastPathComponent ?? ""
        // Beim Wechsel in den Tab die Vorschau auffrischen – im Finder kann sich inzwischen etwas geändert haben.
        if case .applying = phase { return }
        if case .done = phase { return }
        startPlanning()
    }

    // MARK: - Darstellung

    private func render() {
        let busy: Bool
        switch phase {
        case .planning, .applying: busy = true
        default: busy = false
        }

        show(sourceButton, source, placeholder: "Kein Export-Ordner gewählt")
        show(destinationButton, destination, placeholder: "Kein Zielordner gewählt")
        datesCheckbox.state = setsCaptureDates ? .on : .off
        for control in [chooseSourceButton, chooseDestinationButton, datesCheckbox] as [NSControl] { control.isEnabled = !busy }
        refreshButton.isEnabled = !busy && source != nil && destination != nil

        messageView.isHidden = true
        progressView.isHidden = true
        scrollView.isHidden = true
        switch phase {
        case .idle where source == nil:
            messageView.isHidden = false
            messageView.show(symbol: "calendar.badge.plus", title: "Export aus Fotos einsortieren",
                             text: "PhotoHub kopiert Tagesordner wie „1. August 2026“ aus einem Export der Fotos-App in "
                                 + "Jahr/Monat-Ordner (2026/08) im Ziel. Der Export bleibt unverändert, du kannst also jederzeit "
                                 + "neu anfangen. Den Export-Ordner kannst du auch in dieses Fenster ziehen.",
                             buttonTitle: "Export-Ordner wählen …") { [weak self] in self?.chooseSource() }
        case .idle where destination == nil:
            messageView.isHidden = false
            messageView.show(symbol: "folder.badge.plus", title: "Zielordner wählen",
                             text: "In den Zielordner kommen die Jahr/Monat-Ordner, z. B. dein Foto-Backup. Vorhandene Dateien bleiben unverändert.",
                             buttonTitle: "Zielordner wählen …") { [weak self] in self?.chooseDestination() }
        case .idle, .planning:
            progressView.isHidden = false
            progressView.update(ScanProgress(message: "Prüfe Export-Ordner …"))
            progressView.cancelButton.isHidden = true
        case .applying:
            progressView.isHidden = false
            progressView.cancelButton.isHidden = false
        case .ready where rows.isEmpty:
            messageView.isHidden = false
            messageView.show(symbol: "tray", title: "Nichts zu kopieren",
                             text: "Im Export-Ordner liegen keine Tagesordner wie „1. August 2026“.")
        case .ready:
            scrollView.isHidden = false
        case .done(let outcome):
            messageView.isHidden = false
            messageView.show(symbol: outcome.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                             title: outcome.wasCancelled ? "Abgebrochen" : "Kopiert", text: describe(outcome),
                             buttonTitle: "Neue Vorschau") { [weak self] in self?.refresh() }
        case .failed(let title, let message):
            messageView.isHidden = false
            messageView.show(symbol: "exclamationmark.triangle", title: title, text: message,
                             buttonTitle: "Erneut versuchen") { [weak self] in self?.refresh() }
        }
        tableView.reloadData()
        updateBottomBar(busy: busy)
    }

    private func show(_ button: NSButton, _ url: URL?, placeholder: String) {
        button.title = url?.path ?? placeholder
        button.image = NSImage(systemSymbolName: url == nil ? "folder" : "folder.fill", accessibilityDescription: nil)
        button.contentTintColor = url == nil ? .secondaryLabelColor : .labelColor
        button.toolTip = url == nil ? nil : "Im Finder zeigen"
    }

    private func updateBottomBar(busy: Bool) {
        let ready: Bool
        if case .ready = phase { ready = true } else { ready = false }
        let visible = ready || lastOutcome != nil
        bottomBar.isHidden = !visible
        bottomSeparator.isHidden = !visible
        guard visible else { return }

        summaryLabel.isHidden = !ready
        var parts = [plural(plan.folders.count, "Tagesordner", "Tagesordner"), "\(plural(plan.copyCount, "Datei", "Dateien")) zu kopieren"]
        if plan.copyCount > 0 { parts[1] += " (\(plan.copyBytes.formattedBytes))" }
        if plan.renameCount > 0 { parts.append("\(plan.renameCount.formatted()) umbenannt") }
        if plan.alreadyCopiedCount > 0 { parts.append("\(plan.alreadyCopiedCount.formatted()) schon im Ziel") }
        if !plan.unrecognized.isEmpty { parts.append(plural(plan.unrecognized.count, "Ordner", "Ordner") + " nicht erkannt") }
        summaryLabel.stringValue = parts.joined(separator: " · ")

        if let outcome = lastOutcome {
            undoLabel.stringValue = "\(plural(outcome.copied.count, "Datei", "Dateien")) kopiert"
            undoLabel.isHidden = false
            undoButton.isHidden = false
            undoButton.isEnabled = !busy
        } else {
            undoLabel.isHidden = true
            undoButton.isHidden = true
        }
        duplicatesButton.isHidden = lastOutcome == nil || onFindDuplicates == nil
        applyButton.isHidden = !ready
        applyButton.isEnabled = ready && plan.copyCount > 0
    }

    private func describe(_ outcome: ExportSorter.Outcome) -> String {
        var sentences = ["\(plural(outcome.copied.count, "Datei", "Dateien")) nach „\(destination?.lastPathComponent ?? "Ziel")“ kopiert"
            + (outcome.renamedCount > 0 ? ", davon \(outcome.renamedCount.formatted()) wegen gleicher Namen umbenannt." : ".")
            + " Der Export ist unverändert."]
        if setsCaptureDates && !outcome.copied.isEmpty {
            sentences.append("Aufnahmezeit bei \(plural(outcome.datesSet, "Kopie", "Kopien")) als Dateidatum gesetzt"
                + (outcome.datesMissing > 0 ? ", \(outcome.datesMissing.formatted()) ohne Aufnahmezeit unverändert." : "."))
        }
        if outcome.alreadyCopiedCount > 0 {
            sentences.append("\(plural(outcome.alreadyCopiedCount, "Datei lag", "Dateien lagen")) schon im Ziel und wurde\(outcome.alreadyCopiedCount == 1 ? "" : "n") übersprungen.")
        }
        if !outcome.failures.isEmpty {
            sentences.append("Nicht kopiert: " + outcome.failures.prefix(5).joined(separator: "; ") + (outcome.failures.count > 5 ? " …" : ""))
        }
        sentences.append("„Rückgängig“ legt die Kopien in den Papierkorb.")
        return sentences.joined(separator: " ")
    }

    // MARK: - Ablauf

    private func startPlanning() {
        guard let source, let destination else {
            phase = .idle
            render()
            return
        }
        task?.cancel()
        runID += 1
        let id = runID
        phase = .planning
        render()
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportSorter.plan(source: source, destination: destination) }
            }.value
            guard let self, id == self.runID else { return }
            switch result {
            case .success(let plan):
                self.plan = plan
                self.rows = plan.folders.map(Row.folder) + plan.unrecognized.map(Row.unrecognized)
                self.phase = .ready
            case .failure(let error):
                self.plan = ExportSorter.Plan()
                self.rows = []
                self.phase = .failed(title: "Vorschau nicht möglich", message: error.localizedDescription)
            }
            self.render()
        }
    }

    @objc private func confirmApply() {
        guard case .ready = phase, plan.copyCount > 0, let window = view.window, let destination else { return }
        let alert = NSAlert()
        alert.messageText = "\(plural(plan.copyCount, "Datei", "Dateien")) aus \(plural(plan.folders.count, "Tagesordner", "Tagesordnern")) "
            + "nach „\(destination.lastPathComponent)“ kopieren?"
        var text = ["Insgesamt \(plan.copyBytes.formattedBytes). Der Export bleibt unverändert."]
        if plan.renameCount > 0 { text.append("\(plural(plan.renameCount, "Datei wird", "Dateien werden")) wegen gleicher Namen im Ziel umbenannt (…_1).") }
        if plan.alreadyCopiedCount > 0 { text.append("\(plural(plan.alreadyCopiedCount, "Datei liegt", "Dateien liegen")) schon im Ziel und \(plan.alreadyCopiedCount == 1 ? "wird" : "werden") übersprungen.") }
        if setsCaptureDates { text.append("Das Dateidatum der Kopien wird auf die Aufnahmezeit gesetzt.") }
        text.append("„Rückgängig“ legt die Kopien in den Papierkorb.")
        alert.informativeText = text.joined(separator: "\n")
        alert.addButton(withTitle: "Kopieren")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.apply() }
        }
    }

    private func apply() {
        guard let source, let destination else { return }
        task?.cancel()
        runID += 1
        let id = runID
        let setDates = setsCaptureDates
        phase = .applying
        progressView.update(ScanProgress(message: "Kopiere …", done: 0, total: plan.copyCount))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        // Eigene Task, damit „Abbrechen“ die Arbeit selbst erreicht (verschachtelte Tasks erben den Abbruch nicht).
        let work = Task.detached(priority: .userInitiated) { () -> Result<ExportSorter.Outcome, Error> in
            do {
                return .success(try await ExportSorter.apply(source: source, destination: destination, setCaptureDates: setDates, progress: report))
            } catch {
                return .failure(error)
            }
        }
        applyWork = work
        task = Task { [weak self] in
            let result = await work.value
            guard let self else { return }
            self.applyWork = nil
            switch result {
            case .success(let outcome):
                self.lastOutcome = outcome.copied.isEmpty ? nil : outcome
                self.phase = .done(outcome)
            case .failure(let error):
                self.phase = .failed(title: "Kopieren nicht möglich", message: error.localizedDescription)
            }
            self.render()
        }
    }

    @objc private func cancel() {
        guard case .applying = phase else { return }
        applyWork?.cancel()
    }

    @objc private func undo() {
        guard let outcome = lastOutcome else { return }
        lastOutcome = nil
        phase = .planning
        render()
        Task { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) { ExportSorter.undo(outcome) }.value
            guard let self else { return }
            self.startPlanning()
            if !failures.isEmpty { self.showError("\(plural(failures.count, "Kopie konnte", "Kopien konnten")) nicht in den Papierkorb "
                + "gelegt werden:\n\n" + failures.prefix(8).joined(separator: "\n")) }
        }
    }

    @objc private func findDuplicates() {
        guard let destination else { return }
        onFindDuplicates?(destination)
    }

    @objc private func refresh() {
        startPlanning()
    }

    private func showError(_ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hinweis"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - Ordner wählen

    private func setSource(_ url: URL) {
        if case .applying = phase { return }
        source = url.standardizedFileURL
        defaults.set(source?.path, forKey: Keys.source)
        view.window?.subtitle = url.lastPathComponent
        startPlanning()
    }

    private func setDestination(_ url: URL) {
        if case .applying = phase { return }
        destination = url.standardizedFileURL
        defaults.set(destination?.path, forKey: Keys.destination)
        startPlanning()
    }

    @objc private func chooseSource() {
        choose(message: "Wähle den Ordner mit dem Export aus Fotos (enthält Ordner wie „1. August 2026“)",
               current: source, canCreate: false) { [weak self] url in self?.setSource(url) }
    }

    @objc private func chooseDestination() {
        choose(message: "Wähle den Zielordner für die Jahr/Monat-Ordner", current: destination, canCreate: true) { [weak self] url in
            self?.setDestination(url)
        }
    }

    private func choose(message: String, current: URL?, canCreate: Bool, completion: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = message
        panel.directoryURL = current ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    @objc private func datesChanged() {
        setsCaptureDates = datesCheckbox.state == .on
        defaults.set(setsCaptureDates, forKey: Keys.setsCaptureDates)
    }

    @objc private func revealSource() {
        if let source { NSWorkspace.shared.activateFileViewerSelecting([source]) }
    }

    @objc private func revealDestination() {
        if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    }

    @objc private func revealRow() {
        guard rows.indices.contains(tableView.clickedRow) else { return }
        switch rows[tableView.clickedRow] {
        case .folder(let folder): NSWorkspace.shared.activateFileViewerSelecting([folder.source])
        case .unrecognized(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - Vorschau-Tabelle

extension SortViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if case .ready = phase { return rows.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let field = cell.textField!
        field.textColor = .labelColor
        field.toolTip = nil
        cell.imageView?.image = nil

        func count(_ value: Int) -> String { value == 0 ? "–" : value.formatted() }
        switch (rows[row], id.rawValue) {
        case (.folder(let folder), "folder"):
            field.stringValue = folder.source.lastPathComponent
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        case (.folder(let folder), "target"):
            field.stringValue = folder.targetName
        case (.folder(let folder), "copies"):
            field.stringValue = count(folder.copies.count)
        case (.folder(let folder), "renamed"):
            field.stringValue = count(folder.renamedCount)
            let renamed = folder.copies.filter(\.isRenamed).map { "\($0.source.lastPathComponent) → \($0.target.lastPathComponent)" }
            field.toolTip = renamed.isEmpty ? nil : renamed.prefix(15).joined(separator: "\n")
        case (.folder(let folder), "present"):
            field.stringValue = count(folder.alreadyCopied.count)
            field.toolTip = folder.alreadyCopied.isEmpty ? nil : folder.alreadyCopied.prefix(15).map(\.lastPathComponent).joined(separator: "\n")
        case (.folder(let folder), "note"):
            var notes: [String] = []
            if folder.renamedCount > 0 { notes.append("Name im Ziel schon vergeben") }
            if folder.copies.isEmpty { notes.append("Alles schon im Ziel") }
            field.stringValue = notes.joined(separator: " · ")
            field.textColor = .secondaryLabelColor
        case (.unrecognized(let url), "folder"):
            field.stringValue = url.lastPathComponent
            field.textColor = .secondaryLabelColor
            cell.imageView?.image = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)
        case (.unrecognized, "note"):
            field.stringValue = "Kein Datum im Namen – bleibt unverändert"
            field.textColor = .secondaryLabelColor
        case (.unrecognized, _):
            field.stringValue = "–"
            field.textColor = .tertiaryLabelColor
        default:
            field.stringValue = ""
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        var constraints = [field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                           field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)]
        if id.rawValue == "folder" {
            let image = NSImageView()
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                            image.widthAnchor.constraint(equalToConstant: 18),
                            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4)]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        if ["copies", "renamed", "present"].contains(id.rawValue) {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}
