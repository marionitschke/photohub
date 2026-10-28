import AppKit

/// Tab „Bilder-Datum korrigieren“: Erstellt, Geändert und Hinzugefügt von Fotos und Videos auf die Aufnahmezeit setzen.
final class DateFixViewController: NSViewController {
    enum Phase {
        case idle
        case checking
        case ready
        case applying
        case done(DateFixer.Outcome)
        case failed(title: String, message: String)
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let folder = "fixFolderPath"
        static let subfolders = "fixIncludeSubfolders"
    }

    private var folder: URL?
    private var includeSubfolders = true
    private var phase: Phase = .idle
    private var plan = DateFixer.Plan()
    private var lastOutcome: DateFixer.Outcome?
    private var task: Task<Void, Never>?
    private var runID = 0
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    // Kopfzeile
    private lazy var folderButton = NSButton(title: "", target: self, action: #selector(revealFolder))
    private lazy var chooseButton = NSButton(title: "Wählen …", target: self, action: #selector(chooseFolder))
    private lazy var subfolderCheckbox = NSButton(checkboxWithTitle: "Unterordner einbeziehen", target: self, action: #selector(subfoldersChanged))
    private lazy var checkButton = NSButton(title: "Prüfen", target: self, action: #selector(check))

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
    private lazy var applyButton = NSButton(title: "Datum korrigieren …", target: self, action: #selector(confirmApply))

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Bilder-Datum korrigieren"
        if let path = defaults.string(forKey: Keys.folder) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                folder = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        includeSubfolders = defaults.object(forKey: Keys.subfolders) as? Bool ?? true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    // MARK: - Aufbau

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
        root.onDropFolder = { [weak self] url in self?.setFolder(url) }
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

    private func makeTopBar() -> NSView {
        folderButton.isBordered = false
        folderButton.imagePosition = .imageLeading
        folderButton.alignment = .left
        folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.setContentHuggingPriority(.init(1), for: .horizontal)
        folderButton.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        subfolderCheckbox.toolTip = "Auch alle Unterordner durchsuchen. Fotos-Mediatheken und versteckte Dateien werden nie verändert."
        checkButton.toolTip = "Aufnahmezeit aller Fotos und Videos lesen und mit dem Dateidatum vergleichen"

        let label = NSTextField(labelWithString: "Ordner:")
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, folderButton, chooseButton, subfolderCheckbox, checkButton])
        row.spacing = 10
        row.setCustomSpacing(18, after: chooseButton)

        let bar = NSStackView(views: [row])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -28).isActive = true
        return bar
    }

    private func makeBottomBar() -> NSView {
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(10), for: .horizontal)
        undoLabel.lineBreakMode = .byTruncatingTail
        undoLabel.setContentCompressionResistancePriority(.init(20), for: .horizontal)
        applyButton.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: nil)
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
            ("file", "Datei", 330),
            ("capture", "Aufnahmezeit", 170),
            ("created", "Erstellt", 170),
            ("modified", "Geändert", 170),
            ("added", "Hinzugefügt", 170),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 80
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
        view.window?.subtitle = folder?.lastPathComponent ?? ""
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
        if let folder {
            folderButton.title = folder.path
            folderButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            folderButton.contentTintColor = .labelColor
            folderButton.toolTip = "Im Finder zeigen"
        } else {
            folderButton.title = "Kein Ordner gewählt"
            folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            folderButton.contentTintColor = .secondaryLabelColor
            folderButton.toolTip = nil
        }
        subfolderCheckbox.state = includeSubfolders ? .on : .off
        chooseButton.isEnabled = !busy
        subfolderCheckbox.isEnabled = !busy
        checkButton.isEnabled = !busy && folder != nil
        if case .idle = phase { checkButton.title = "Prüfen" } else { checkButton.title = "Neu prüfen" }

        messageView.isHidden = true
        progressView.isHidden = true
        scrollView.isHidden = true
        switch phase {
        case .idle where folder == nil:
            messageView.isHidden = false
            messageView.show(symbol: "calendar.badge.clock", title: "Dateidatum korrigieren",
                             text: "PhotoHub liest die Aufnahmezeit aller Fotos und Videos aus ihren Metadaten und setzt „Erstellt“, "
                                 + "„Geändert“ und „Hinzugefügt“ im Finder darauf – wie der Tab „Apple Fotos Export“. Die Bilder selbst "
                                 + "bleiben unverändert. Du kannst den Ordner auch in dieses Fenster ziehen.",
                             buttonTitle: "Ordner wählen …") { [weak self] in self?.chooseFolder() }
        case .idle:
            messageView.isHidden = false
            messageView.show(symbol: "magnifyingglass", title: "Bereit zum Prüfen",
                             text: "Vor jeder Änderung siehst du, welche Dateien betroffen sind und welches Datum sie bekommen.",
                             buttonTitle: "Jetzt prüfen") { [weak self] in self?.check() }
        case .checking, .applying:
            progressView.isHidden = false
        case .ready where plan.toFix.isEmpty:
            messageView.isHidden = false
            var text = "Bei \(plural(plan.correctCount, "Datei", "Dateien")) stimmen Erstellt, Geändert und Hinzugefügt schon mit der Aufnahmezeit überein."
            if !plan.withoutDate.isEmpty { text += " \(plural(plan.withoutDate.count, "Datei", "Dateien")) ohne Aufnahmezeit bleiben, wie sie sind." }
            messageView.show(symbol: "checkmark.seal", title: plan.checkedCount == 0 ? "Keine Fotos gefunden" : "Alles stimmt",
                             text: plan.checkedCount == 0 ? "In diesem Ordner liegen keine Fotos oder Videos." : text)
        case .ready:
            scrollView.isHidden = false
        case .done(let outcome):
            messageView.isHidden = false
            var text = "Bei \(plural(outcome.changed.count, "Datei", "Dateien")) zeigen Erstellt, Geändert und Hinzugefügt jetzt die Aufnahmezeit."
            if !outcome.failures.isEmpty {
                text += " Nicht geändert: " + outcome.failures.prefix(5).joined(separator: "; ") + (outcome.failures.count > 5 ? " …" : "")
            }
            text += " „Rückgängig“ stellt die alten Daten wieder her."
            messageView.show(symbol: outcome.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                             title: outcome.wasCancelled ? "Abgebrochen" : "Datum korrigiert", text: text,
                             buttonTitle: "Neu prüfen") { [weak self] in self?.check() }
        case .failed(let title, let message):
            messageView.isHidden = false
            messageView.show(symbol: "exclamationmark.triangle", title: title, text: message,
                             buttonTitle: "Erneut versuchen") { [weak self] in self?.check() }
        }
        tableView.reloadData()
        updateBottomBar(busy: busy)
    }

    private func updateBottomBar(busy: Bool) {
        let ready: Bool
        if case .ready = phase { ready = true } else { ready = false }
        let visible = ready || lastOutcome != nil
        bottomBar.isHidden = !visible
        bottomSeparator.isHidden = !visible
        guard visible else { return }

        summaryLabel.isHidden = !ready
        var parts = ["\(plural(plan.checkedCount, "Datei", "Dateien")) geprüft", "\(plan.toFix.count.formatted()) zu korrigieren"]
        if plan.correctCount > 0 { parts.append("\(plan.correctCount.formatted()) stimmen schon") }
        if !plan.withoutDate.isEmpty { parts.append("\(plan.withoutDate.count.formatted()) ohne Aufnahmezeit") }
        if plan.notDownloadedCount > 0 { parts.append("\(plan.notDownloadedCount.formatted()) nur in iCloud") }
        summaryLabel.stringValue = parts.joined(separator: " · ")
        summaryLabel.toolTip = plan.withoutDate.isEmpty ? nil
            : "Ohne Aufnahmezeit:\n" + plan.withoutDate.prefix(20).map(relativePath).joined(separator: "\n") + (plan.withoutDate.count > 20 ? "\n…" : "")

        if let outcome = lastOutcome {
            undoLabel.stringValue = "\(plural(outcome.changed.count, "Datei", "Dateien")) korrigiert"
            undoLabel.isHidden = false
            undoButton.isHidden = false
            undoButton.isEnabled = !busy
        } else {
            undoLabel.isHidden = true
            undoButton.isHidden = true
        }
        applyButton.isHidden = !ready
        applyButton.isEnabled = ready && !plan.toFix.isEmpty
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = folder?.path, url.path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count + 1))
    }

    // MARK: - Ablauf

    @objc private func check() {
        guard let folder, !isBusy else { return }
        runID += 1
        let id = runID
        let recursive = includeSubfolders
        phase = .checking
        progressView.update(ScanProgress(message: "Suche Fotos und Videos …"))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        // Eigene Task für die Arbeit; „Abbrechen“ reicht den Abbruch weiter (verschachtelte Tasks erben ihn nicht).
        let job = Task.detached(priority: .userInitiated) { () -> Result<DateFixer.Plan, Error> in
            do {
                return .success(try await DateFixer.plan(folder: folder, recursive: recursive, progress: report))
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
                self.phase = .failed(title: "Prüfen nicht möglich", message: error.localizedDescription)
            }
            self.render()
        }
    }

    @objc private func confirmApply() {
        guard case .ready = phase, !plan.toFix.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Bei \(plural(plan.toFix.count, "Datei", "Dateien")) das Datum korrigieren?"
        var text = ["„Erstellt“, „Geändert“ und „Hinzugefügt“ werden auf die Aufnahmezeit aus den Metadaten gesetzt. Die Bilddaten bleiben unverändert."]
        if !plan.withoutDate.isEmpty { text.append("\(plural(plan.withoutDate.count, "Datei", "Dateien")) ohne Aufnahmezeit bleiben, wie sie sind.") }
        text.append("„Rückgängig“ stellt die alten Daten wieder her, solange PhotoHub geöffnet ist.")
        alert.informativeText = text.joined(separator: "\n")
        alert.addButton(withTitle: "Korrigieren")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.apply() }
        }
    }

    private func apply() {
        runID += 1
        let id = runID
        let plan = plan
        phase = .applying
        progressView.update(ScanProgress(message: "Korrigiere Datum …", done: 0, total: plan.toFix.count))
        render()
        let report: PhotoScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, id == self.runID else { return }
                self.progressView.update(progress)
            }
        }
        let job = Task.detached(priority: .userInitiated) { DateFixer.apply(plan, progress: report) }
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            self.lastOutcome = outcome.changed.isEmpty ? nil : outcome
            self.phase = .done(outcome)
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
            let failures = await Task.detached(priority: .userInitiated) { DateFixer.undo(outcome) }.value
            guard let self else { return }
            self.phase = .idle
            self.render()
            self.check()
            if !failures.isEmpty, let window = self.view.window {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Hinweis"
                alert.informativeText = "Bei \(plural(failures.count, "Datei", "Dateien")) ließ sich das alte Datum nicht wiederherstellen:\n\n"
                    + failures.prefix(8).joined(separator: "\n")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    // MARK: - Ordner

    private func setFolder(_ url: URL) {
        guard !isBusy else { return }
        folder = url.standardizedFileURL
        defaults.set(folder?.path, forKey: Keys.folder)
        view.window?.subtitle = url.lastPathComponent
        lastOutcome = nil
        check()
    }

    @objc private func chooseFolder() {
        guard let window = view.window, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Wähle den Ordner, dessen Fotos und Videos das Datum der Aufnahme bekommen sollen"
        panel.directoryURL = folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setFolder(url)
        }
    }

    @objc private func subfoldersChanged() {
        includeSubfolders = subfolderCheckbox.state == .on
        defaults.set(includeSubfolders, forKey: Keys.subfolders)
        if folder != nil { check() }
    }

    @objc private func revealFolder() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    @objc private func revealRow() {
        guard plan.toFix.indices.contains(tableView.clickedRow) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([plan.toFix[tableView.clickedRow].url])
    }
}

// MARK: - Tabelle

extension DateFixViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if case .ready = phase { return plan.toFix.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let field = cell.textField!
        let item = plan.toFix[row]
        // Abweichende Daten orange, passende grau – so sieht man, was sich ändert.
        func show(_ date: Date?) {
            field.stringValue = date.map(dateFormatter.string) ?? "–"
            let matches = date.map { abs($0.timeIntervalSince(item.captureDate)) < 1 } ?? true
            field.textColor = matches ? .secondaryLabelColor : .systemOrange
        }
        switch id.rawValue {
        case "file":
            field.stringValue = relativePath(item.url)
            field.textColor = .labelColor
            field.toolTip = item.path
        case "capture":
            field.stringValue = dateFormatter.string(from: item.captureDate)
            field.textColor = .labelColor
        case "created": show(item.current.created)
        case "modified": show(item.current.modified)
        case "added": show(item.current.added)
        default: field.stringValue = ""
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = id.rawValue == "file" ? .byTruncatingHead : .byTruncatingTail
        field.font = id.rawValue == "file" ? .systemFont(ofSize: NSFont.systemFontSize) : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
