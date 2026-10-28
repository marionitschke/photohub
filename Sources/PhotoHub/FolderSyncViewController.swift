import AppKit

/// Tab „Bilder-Ordner abgleichen“: Fotos und Videos aus A, die in B fehlen, in denselben Unterordner nach B verschieben.
final class FolderSyncViewController: NSViewController {
    enum Phase {
        case idle
        case checking
        case ready
        case applying
        case done(FolderSync.Outcome)
        case failed(title: String, message: String)
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let source = "syncSourcePath"
        static let destination = "syncDestinationPath"
    }

    private var source: URL?
    private var destination: URL?
    private var phase: Phase = .idle
    private var plan = FolderSync.Plan()
    private var lastOutcome: FolderSync.Outcome?
    private var task: Task<Void, Never>?
    private var runID = 0

    // Kopfzeile
    private lazy var sourceButton = pathButton(action: #selector(revealSource))
    private lazy var destinationButton = pathButton(action: #selector(revealDestination))
    private lazy var chooseSourceButton = NSButton(title: "Wählen …", target: self, action: #selector(chooseSource))
    private lazy var chooseDestinationButton = NSButton(title: "Wählen …", target: self, action: #selector(chooseDestination))
    private let hintLabel = NSTextField(labelWithString: "Verglichen wird der Inhalt: Liegt dieselbe Datei irgendwo in B, egal unter welchem Namen, bleibt sie in A.")
    private lazy var checkButton = NSButton(title: "Vergleichen", target: self, action: #selector(check))

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
    private lazy var applyButton = NSButton(title: "Nach B verschieben …", target: self, action: #selector(confirmApply))

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Bilder-Ordner abgleichen"
        source = defaults.string(forKey: Keys.source).flatMap(Self.existingFolder)
        destination = defaults.string(forKey: Keys.destination).flatMap(Self.existingFolder)
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
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        checkButton.toolTip = "A und B erneut durchsuchen und vergleichen"
        let options = NSStackView(views: [hintLabel, NSView(), checkButton])
        options.views[1].setContentHuggingPriority(.init(1), for: .horizontal)

        let grid = NSGridView(views: [
            [label("Quelle (A):"), sourceButton, chooseSourceButton],
            [label("Ergänzen (B):"), destinationButton, chooseDestinationButton],
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
        applyButton.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        applyButton.imagePosition = .imageLeading
        applyButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bottomBar.setViews([summaryLabel, undoLabel, undoButton, spacer, applyButton], in: .leading)
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 10
        bottomBar.setCustomSpacing(16, after: summaryLabel)
        bottomBar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return bottomBar
    }

    private func setUpTable() {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("file", "Fehlt in B – aus A", 420),
            ("target", "Ziel in B", 420),
            ("size", "Größe", 90),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 80
            if spec.id == "size" { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
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
        updateSubtitle()
    }

    private func updateSubtitle() {
        view.window?.subtitle = [source, destination].compactMap { $0?.lastPathComponent }.joined(separator: " → ")
    }

    // MARK: - Darstellung

    private var isBusy: Bool {
        switch phase {
        case .checking, .applying: return true
        default: return false
        }
    }

    private func render() {
        let busy = isBusy
        show(sourceButton, source, placeholder: "Kein Ordner A gewählt")
        show(destinationButton, destination, placeholder: "Kein Ordner B gewählt")
        chooseSourceButton.isEnabled = !busy
        chooseDestinationButton.isEnabled = !busy
        checkButton.isEnabled = !busy && source != nil && destination != nil
        if case .idle = phase { checkButton.title = "Vergleichen" } else { checkButton.title = "Neu vergleichen" }

        messageView.isHidden = true
        progressView.isHidden = true
        scrollView.isHidden = true
        switch phase {
        case .idle where source == nil:
            messageView.isHidden = false
            messageView.show(symbol: "arrow.triangle.2.circlepath", title: "Ordner abgleichen",
                             text: "PhotoHub sucht die Fotos und Videos aus Ordner A, die in Ordner B fehlen, und verschiebt sie "
                                 + "nach B – in denselben Unterordner wie in A. Verglichen wird der Inhalt, nicht der Name. "
                                 + "Ordner A kannst du auch in dieses Fenster ziehen.",
                             buttonTitle: "Ordner A wählen …") { [weak self] in self?.chooseSource() }
        case .idle where destination == nil:
            messageView.isHidden = false
            messageView.show(symbol: "folder.badge.plus", title: "Ordner B wählen",
                             text: "In Ordner B kommen die Fotos und Videos aus A, die dort fehlen. Was schon in B liegt, bleibt unverändert.",
                             buttonTitle: "Ordner B wählen …") { [weak self] in self?.chooseDestination() }
        case .idle:
            messageView.isHidden = false
            messageView.show(symbol: "magnifyingglass", title: "Bereit zum Vergleichen",
                             text: "Vor dem Verschieben siehst du, welche Dateien in B fehlen und wo sie landen.",
                             buttonTitle: "Jetzt vergleichen") { [weak self] in self?.check() }
        case .checking, .applying:
            progressView.isHidden = false
        case .ready where plan.moves.isEmpty:
            messageView.isHidden = false
            var text = "Alle \(plural(plan.checkedCount, "Datei", "Dateien")) aus A liegen schon in B."
            if plan.notDownloadedInSource > 0 { text += " \(plural(plan.notDownloadedInSource, "Datei", "Dateien")) in A liegen nur in iCloud und wurden nicht verglichen." }
            messageView.show(symbol: "checkmark.seal", title: plan.checkedCount == 0 ? "Keine Fotos gefunden" : "Nichts fehlt in B",
                             text: plan.checkedCount == 0 ? "In Ordner A liegen keine Fotos oder Videos." : text)
        case .ready:
            scrollView.isHidden = false
        case .done(let outcome):
            messageView.isHidden = false
            messageView.show(symbol: outcome.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                             title: outcome.wasCancelled ? "Abgebrochen" : "Verschoben", text: describe(outcome),
                             buttonTitle: "Neu vergleichen") { [weak self] in self?.check() }
        case .failed(let title, let message):
            messageView.isHidden = false
            messageView.show(symbol: "exclamationmark.triangle", title: title, text: message,
                             buttonTitle: "Erneut versuchen") { [weak self] in self?.check() }
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
        var parts = ["\(plural(plan.checkedCount, "Datei", "Dateien")) in A", "\(plan.moves.count.formatted()) fehlen in B"]
        if !plan.moves.isEmpty { parts[1] += " (\(plan.moveBytes.formattedBytes))" }
        if plan.renameCount > 0 { parts.append("\(plan.renameCount.formatted()) umbenannt") }
        if plan.presentCount > 0 { parts.append("\(plan.presentCount.formatted()) schon in B") }
        if plan.duplicateCount > 0 { parts.append("\(plan.duplicateCount.formatted()) doppelt in A") }
        let notDownloaded = plan.notDownloadedInSource + plan.notDownloadedInDestination
        if notDownloaded > 0 { parts.append("\(notDownloaded.formatted()) nur in iCloud") }
        summaryLabel.stringValue = parts.joined(separator: " · ")
        var notes: [String] = []
        if plan.duplicateCount > 0 { notes.append("Doppelt in A: gleicher Inhalt wie eine andere Datei aus A, die nach B wandert – bleibt in A.") }
        if plan.notDownloadedInSource > 0 { notes.append("\(plural(plan.notDownloadedInSource, "Datei", "Dateien")) in A nur in iCloud – nicht verglichen, bleiben in A.") }
        if plan.notDownloadedInDestination > 0 { notes.append("\(plural(plan.notDownloadedInDestination, "Datei", "Dateien")) in B nur in iCloud – nicht verglichen.") }
        if plan.otherFileCount > 0 { notes.append("\(plural(plan.otherFileCount, "andere Datei", "andere Dateien")) in A (keine Fotos oder Videos) bleiben liegen.") }
        summaryLabel.toolTip = notes.isEmpty ? nil : notes.joined(separator: "\n")

        if let outcome = lastOutcome {
            undoLabel.stringValue = "\(plural(outcome.moved.count, "Datei", "Dateien")) nach B verschoben"
            undoLabel.isHidden = false
            undoButton.isHidden = false
            undoButton.isEnabled = !busy
        } else {
            undoLabel.isHidden = true
            undoButton.isHidden = true
        }
        applyButton.isHidden = !ready
        applyButton.isEnabled = ready && !plan.moves.isEmpty
    }

    private func describe(_ outcome: FolderSync.Outcome) -> String {
        var sentences = ["\(plural(outcome.moved.count, "Datei", "Dateien")) von „\(source?.lastPathComponent ?? "A")“ nach "
            + "„\(destination?.lastPathComponent ?? "B")“ verschoben. Erstellt, Geändert und Hinzugefügt sind wie vorher."]
        if !outcome.failures.isEmpty {
            sentences.append("Nicht verschoben: " + outcome.failures.prefix(5).joined(separator: "; ") + (outcome.failures.count > 5 ? " …" : ""))
        } else if !outcome.wasCancelled && plan.notDownloadedInSource == 0 {
            sentences.append("Alle Fotos und Videos, die noch in A liegen, gibt es auch in B.")
        }
        sentences.append("„Rückgängig“ verschiebt sie zurück nach A.")
        return sentences.joined(separator: " ")
    }

    // MARK: - Ablauf

    @objc private func check() {
        guard let source, let destination, !isBusy else { return }
        runID += 1
        let id = runID
        phase = .checking
        progressView.update(ScanProgress(message: "Suche Fotos und Videos in A …"))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        // Eigene Task für die Arbeit; „Abbrechen“ reicht den Abbruch weiter (verschachtelte Tasks erben ihn nicht).
        let job = Task.detached(priority: .userInitiated) { () -> Result<FolderSync.Plan, Error> in
            let cache = ScanCache.shared
            defer { cache.save() }
            do {
                return .success(try await FolderSync.plan(source: source, destination: destination, cache: cache, progress: report))
            } catch {
                return .failure(error)
            }
        }
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, id == self.runID else { return }
            switch outcome {
            case .success(let plan):
                self.plan = plan
                self.phase = .ready
            case .failure(let error) where error is CancellationError:
                self.phase = .idle
            case .failure(let error):
                self.phase = .failed(title: "Vergleichen nicht möglich", message: error.localizedDescription)
            }
            self.render()
        }
    }

    @objc private func confirmApply() {
        guard case .ready = phase, !plan.moves.isEmpty, let window = view.window, let source, let destination else { return }
        let alert = NSAlert()
        alert.messageText = "\(plural(plan.moves.count, "Datei", "Dateien")) von „\(source.lastPathComponent)“ nach „\(destination.lastPathComponent)“ verschieben?"
        var text = ["Insgesamt \(plan.moveBytes.formattedBytes). Jede Datei kommt in denselben Unterordner wie in A, fehlende Ordner werden angelegt."]
        if plan.renameCount > 0 { text.append("\(plural(plan.renameCount, "Datei wird", "Dateien werden")) umbenannt (…_1), weil der Name in B schon für ein anderes Foto vergeben ist.") }
        if plan.acrossVolumes { text.append("A und B liegen auf verschiedenen Laufwerken: Jede Datei wird nach B kopiert und danach in A gelöscht.") }
        text.append("Erstellt, Geändert und Hinzugefügt bleiben erhalten. „Rückgängig“ verschiebt alles zurück, solange PhotoHub geöffnet ist.")
        alert.informativeText = text.joined(separator: "\n")
        alert.addButton(withTitle: "Verschieben")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.apply() }
        }
    }

    private func apply() {
        guard let source, let destination else { return }
        runID += 1
        let id = runID
        let plan = plan
        phase = .applying
        progressView.update(ScanProgress(message: "Verschiebe nach B …", done: 0, total: plan.moves.count))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        let job = Task.detached(priority: .userInitiated) {
            Result { try FolderSync.apply(plan, source: source, destination: destination, progress: report) }
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            switch result {
            case .success(let outcome):
                self.lastOutcome = outcome.moved.isEmpty ? nil : outcome
                self.phase = .done(outcome)
            case .failure(let error):
                self.phase = .failed(title: "Verschieben nicht möglich", message: error.localizedDescription)
            }
            self.render()
        }
    }

    @objc private func cancel() {
        guard isBusy else { return }
        task?.cancel()
    }

    @objc private func undo() {
        guard let outcome = lastOutcome, !isBusy else { return }
        lastOutcome = nil
        Task { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) { FolderSync.undo(outcome) }.value
            guard let self else { return }
            self.phase = .idle
            self.render()
            self.check()
            if !failures.isEmpty, let window = self.view.window {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Hinweis"
                alert.informativeText = "\(plural(failures.count, "Datei ließ", "Dateien ließen")) sich nicht zurück nach A verschieben:\n\n"
                    + failures.prefix(8).joined(separator: "\n")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    // MARK: - Ordner wählen

    private func setSource(_ url: URL) {
        guard !isBusy else { return }
        source = url.standardizedFileURL
        defaults.set(source?.path, forKey: Keys.source)
        foldersChanged()
    }

    private func setDestination(_ url: URL) {
        guard !isBusy else { return }
        destination = url.standardizedFileURL
        defaults.set(destination?.path, forKey: Keys.destination)
        foldersChanged()
    }

    private func foldersChanged() {
        updateSubtitle()
        lastOutcome = nil
        if source != nil && destination != nil {
            check()
        } else {
            phase = .idle
            render()
        }
    }

    @objc private func chooseSource() {
        choose(message: "Wähle Ordner A – aus ihm wandern die Fotos und Videos, die in B fehlen", current: source, canCreate: false) { [weak self] url in
            self?.setSource(url)
        }
    }

    @objc private func chooseDestination() {
        choose(message: "Wähle Ordner B – er wird um die fehlenden Fotos und Videos aus A ergänzt", current: destination, canCreate: true) { [weak self] url in
            self?.setDestination(url)
        }
    }

    private func choose(message: String, current: URL?, canCreate: Bool, completion: @escaping (URL) -> Void) {
        guard let window = view.window, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = message
        panel.directoryURL = current ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    @objc private func revealSource() {
        if let source { NSWorkspace.shared.activateFileViewerSelecting([source]) }
    }

    @objc private func revealDestination() {
        if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    }

    @objc private func revealRow() {
        guard case .ready = phase, plan.moves.indices.contains(tableView.clickedRow) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([plan.moves[tableView.clickedRow].source])
    }
}

// MARK: - Tabelle

extension FolderSyncViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if case .ready = phase { return plan.moves.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let field = cell.textField!
        let move = plan.moves[row]
        field.toolTip = nil
        switch id.rawValue {
        case "file":
            field.stringValue = move.relativeSource
            field.textColor = .labelColor
            field.toolTip = move.sourcePath
        case "target":
            field.stringValue = move.relativeTarget
            // Umbenannte Ziele orange, alle anderen heißen wie in A.
            field.textColor = move.isRenamed ? .systemOrange : .secondaryLabelColor
            field.toolTip = move.isRenamed ? "Der Name ist in B schon für eine andere Datei vergeben." : move.targetPath
        case "size":
            field.stringValue = move.size.formattedBytes
            field.textColor = .secondaryLabelColor
        default:
            field.stringValue = ""
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = id.rawValue == "size" ? .byTruncatingTail : .byTruncatingHead
        if id.rawValue == "size" {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        ])
        return cell
    }
}
