import AppKit

final class MainViewController: NSViewController {
    private let model: AppModel

    // Kopfzeile
    private lazy var chooseButton = NSButton(title: "Ordner wählen …", target: self, action: #selector(chooseFolder(_:)))
    private lazy var folderButton = NSButton(title: "", target: self, action: #selector(revealFolder))
    private lazy var subfolderCheckbox = NSButton(checkboxWithTitle: "Unterordner einbeziehen", target: self, action: #selector(subfoldersChanged))
    private lazy var rawPairCheckbox = NSButton(checkboxWithTitle: "RAW+JPEG als Paar", target: self, action: #selector(rawPairsChanged))
    private lazy var scanButton = NSButton(title: "Scannen", target: self, action: #selector(scanOrCancel))

    // Suchoptionen
    private lazy var identicalCheckbox = NSButton(checkboxWithTitle: "Bytegleiche Kopien", target: self, action: #selector(optionsEdited))
    private lazy var compressedCheckbox = NSButton(checkboxWithTitle: "Komprimierte Kopien (z. B. WhatsApp)", target: self, action: #selector(optionsEdited))
    private lazy var motifCheckbox = NSButton(checkboxWithTitle: "Gleiches Motiv ab", target: self, action: #selector(optionsEdited))
    private lazy var minimumSizeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toleranceLabel = NSTextField(labelWithString: "Toleranz")
    private lazy var toleranceSlider = NSSlider(value: 0, minValue: 0, maxValue: Double(DuplicateFinder.maxTolerance),
                                                target: self, action: #selector(optionsEdited))
    private let toleranceValueLabel = NSTextField(labelWithString: "")

    // Mitte
    private let messageView = MessageView()
    private let progressView = ScanProgressView()
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()

    // Fußzeile
    private let bottomSeparator = NSBox()
    private let bottomBar = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let undoLabel = NSTextField(labelWithString: "")
    private lazy var undoButton = NSButton(title: "Rückgängig", target: self, action: #selector(undoTrash(_:)))
    private let markedLabel = NSTextField(labelWithString: "")
    private let selectionButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private lazy var trashButton = NSButton(title: "In den Papierkorb …", target: self, action: #selector(confirmTrash(_:)))

    private var rootPath = ""
    private var lastPhase: AppModel.Phase = .idle

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "Bilder-Duplikate finden"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    // MARK: - Aufbau

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
        root.onDropFolder = { [weak self] url in self?.useFolder(url) }
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

        setUpCollectionView()
        progressView.cancelButton.target = self
        progressView.cancelButton.action = #selector(cancelScan(_:))
    }

    private func makeTopBar() -> NSView {
        folderButton.isBordered = false
        folderButton.imagePosition = .imageLeading
        folderButton.alignment = .left
        folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.contentTintColor = .labelColor
        folderButton.setContentHuggingPriority(.init(1), for: .horizontal)
        folderButton.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        folderButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        subfolderCheckbox.toolTip = "Auch alle Unterordner durchsuchen"
        rawPairCheckbox.toolTip = "Liegen z. B. DSC_1234.NEF und DSC_1234.JPG im selben Ordner, gelten sie als ein Foto: "
            + "Das JPEG wird nicht als komprimierte Kopie markiert und wandert mit dem RAW in den Papierkorb."

        let folderRow = NSStackView(views: [chooseButton, folderButton, subfolderCheckbox, rawPairCheckbox, scanButton])
        folderRow.spacing = 12
        folderRow.setCustomSpacing(18, after: folderButton)

        identicalCheckbox.toolTip = "Exakt gleiche Dateien, z. B. doppelt importiert oder kopiert. Die Kopien werden zum Löschen markiert."
        compressedCheckbox.toolTip = "Dasselbe Foto in schlechterer Qualität – z. B. per WhatsApp oder Mail geteilt, verkleinert oder "
            + "neu komprimiert. Die schlechtere Version wird zum Löschen markiert."
        motifCheckbox.toolTip = "Verschiedene Aufnahmen mit gleichem Bildaufbau (z. B. Serienbilder, Kopf jeweils links). "
            + "Ein anderer Bildaufbau (Kopf einmal links, einmal rechts) gilt als eigenes Bild. Das beste wird behalten."
        for size in [2, 3, 4, 5, 6, 8, 10] {
            minimumSizeButton.addItem(withTitle: "\(size) Bildern")
            minimumSizeButton.lastItem?.tag = size
        }
        minimumSizeButton.target = self
        minimumSizeButton.action = #selector(optionsEdited)
        minimumSizeButton.toolTip = "Gleiche Motive erst beachten, wenn es mindestens so viele Aufnahmen davon gibt."
        toleranceSlider.isContinuous = true
        toleranceSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        toleranceSlider.toolTip = "Wie genau das Motiv übereinstimmen muss. Niedrig = fast identischer Bildaufbau, hoch = auch leicht verschobene Aufnahmen."
        toleranceValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        toleranceValueLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let findLabel = NSTextField(labelWithString: "Finden:")
        findLabel.textColor = .secondaryLabelColor
        let optionsRow = NSStackView(views: [findLabel, identicalCheckbox, compressedCheckbox, motifCheckbox, minimumSizeButton,
                                             toleranceLabel, toleranceSlider, toleranceValueLabel])
        optionsRow.spacing = 14
        optionsRow.setCustomSpacing(6, after: motifCheckbox)
        optionsRow.setCustomSpacing(16, after: minimumSizeButton)
        optionsRow.setCustomSpacing(6, after: toleranceLabel)
        optionsRow.setCustomSpacing(6, after: toleranceSlider)

        let bar = NSStackView(views: [folderRow, optionsRow])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        folderRow.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -28).isActive = true
        return bar
    }

    private func makeBottomBar() -> NSView {
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(10), for: .horizontal)
        undoLabel.lineBreakMode = .byTruncatingTail
        undoLabel.setContentCompressionResistancePriority(.init(20), for: .horizontal)
        markedLabel.font = .systemFont(ofSize: 13, weight: .medium)
        markedLabel.alignment = .right

        selectionButton.addItem(withTitle: "Auswahl")
        selectionButton.menu?.addItem(ActionMenuItem("Vorschlag übernehmen") { [weak self] in self?.model.applySuggestions() })
        selectionButton.menu?.addItem(ActionMenuItem("Alle Markierungen entfernen") { [weak self] in self?.model.clearMarks() })

        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        trashButton.imagePosition = .imageLeading
        trashButton.bezelColor = .systemRed
        trashButton.hasDestructiveAction = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        bottomBar.setViews([summaryLabel, undoLabel, undoButton, spacer, markedLabel, selectionButton, trashButton], in: .leading)
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 10
        bottomBar.setCustomSpacing(16, after: summaryLabel)
        bottomBar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return bottomBar
    }

    private func setUpCollectionView() {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(PhotoCardView.size.width),
                                                             heightDimension: .absolute(PhotoCardView.size.height)))
        let row = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                        heightDimension: .absolute(PhotoCardView.size.height)),
                                                      subitems: [item])
        row.interItemSpacing = .fixed(12)
        let section = NSCollectionLayoutSection(group: row)
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 22, trailing: 18)
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(48)),
                                                                 elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
        section.boundarySupplementaryItems = [header]

        collectionView.collectionViewLayout = NSCollectionViewCompositionalLayout(section: section)
        collectionView.dataSource = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.windowBackgroundColor]
        collectionView.register(PhotoItem.self, forItemWithIdentifier: PhotoItem.identifier)
        collectionView.register(GroupHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: GroupHeaderView.identifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onChange = { [weak self] change in self?.render(change) }
        model.onError = { [weak self] message in self?.showError(message) }
        render(.all)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowSubtitle()
    }

    // MARK: - Darstellung

    private func render(_ change: AppModel.Change) {
        switch change {
        case .progress:
            progressView.update(model.progress)
        case .marks:
            refreshVisibleCells()
            updateBottomBar()
        case .all:
            updateTopBar()
            updateCenter()
            updateBottomBar()
            updateWindowSubtitle()
        }
    }

    private func updateTopBar() {
        let scanning = model.phase == .scanning
        if let folder = model.folder {
            folderButton.title = folder.path
            folderButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            folderButton.contentTintColor = .labelColor
            folderButton.toolTip = "Im Finder zeigen"
        } else {
            folderButton.title = "Kein Ordner verknüpft"
            folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            folderButton.contentTintColor = .secondaryLabelColor
            folderButton.toolTip = nil
        }
        subfolderCheckbox.state = model.includeSubfolders ? .on : .off
        rawPairCheckbox.state = model.pairRawWithJPEG ? .on : .off
        let options = model.options
        identicalCheckbox.state = options.identical ? .on : .off
        compressedCheckbox.state = options.compressed ? .on : .off
        motifCheckbox.state = options.motif ? .on : .off
        if !minimumSizeButton.selectItem(withTag: options.minimumMotifSize) {
            minimumSizeButton.selectItem(withTag: 3)
        }
        toleranceSlider.integerValue = options.tolerance
        toleranceValueLabel.stringValue = "\(options.tolerance)"

        scanButton.title = scanning ? "Abbrechen" : (model.phase == .done ? "Neu scannen" : "Scannen")
        scanButton.keyEquivalent = scanning ? "\u{1b}" : ""
        scanButton.isEnabled = model.folder != nil && (scanning || !options.isEmpty)
        for control in [chooseButton, subfolderCheckbox, rawPairCheckbox, identicalCheckbox, compressedCheckbox, motifCheckbox] as [NSControl] {
            control.isEnabled = !scanning
        }
        for control in [minimumSizeButton, toleranceSlider] as [NSControl] {
            control.isEnabled = !scanning && options.motif
        }
        toleranceLabel.textColor = options.motif ? .labelColor : .disabledControlTextColor
        toleranceValueLabel.textColor = toleranceLabel.textColor
    }

    private func updateCenter() {
        rootPath = model.folder?.standardizedFileURL.path ?? ""
        messageView.isHidden = true
        progressView.isHidden = true
        scrollView.isHidden = true

        switch model.phase {
        case .idle:
            messageView.isHidden = false
            if model.folder == nil {
                messageView.show(symbol: "photo.on.rectangle.angled", title: "Kein Ordner verknüpft",
                                 text: "Wähle einen Ordner mit Fotos – oder zieh ihn einfach in dieses Fenster. PhotoHub sucht darin nach doppelten Bildern.",
                                 buttonTitle: "Ordner wählen …") { [weak self] in self?.chooseFolder(nil) }
            } else if model.options.isEmpty {
                messageView.show(symbol: "checklist", title: "Was soll gefunden werden?",
                                 text: "Wähle oben unter „Finden“ mindestens eine Art von Duplikaten aus.")
            } else {
                messageView.show(symbol: "magnifyingglass", title: "Bereit zum Scannen", text: searchDescription(),
                                 buttonTitle: "Jetzt scannen") { [weak self] in self?.model.startScan() }
            }
        case .scanning:
            progressView.isHidden = false
            progressView.update(model.progress)
        case .failed(let message):
            messageView.isHidden = false
            messageView.show(symbol: "exclamationmark.triangle", title: "Scan fehlgeschlagen", text: message,
                             buttonTitle: "Erneut versuchen") { [weak self] in self?.model.startScan() }
        case .done where model.groups.isEmpty:
            messageView.isHidden = false
            if let trash = model.lastTrash {
                messageView.show(symbol: "sparkles", title: "Alles aufgeräumt",
                                 text: "\(plural(trash.moves.count, "Datei liegt", "Dateien liegen")) im Papierkorb. Mit „Rückgängig“ holst du sie zurück.")
            } else {
                messageView.show(symbol: "checkmark.seal", title: "Keine Duplikate gefunden",
                                 text: "\(plural(model.scannedCount, "Bild", "Bilder")) durchsucht – nichts gefunden, was zu den gewählten "
                                     + "Optionen passt.",
                                 buttonTitle: "Neu scannen") { [weak self] in self?.model.startScan() }
            }
        case .done:
            scrollView.isHidden = false
        }

        collectionView.reloadData()
        if lastPhase == .scanning, model.phase == .done {
            collectionView.scroll(.zero)
        }
        lastPhase = model.phase
    }

    private func updateBottomBar() {
        let visible = model.phase == .done && (!model.groups.isEmpty || model.lastTrash != nil)
        bottomBar.isHidden = !visible
        bottomSeparator.isHidden = !visible
        guard visible else { return }

        summaryLabel.isHidden = model.groups.isEmpty
        if !model.groups.isEmpty {
            summaryLabel.stringValue = "\(plural(model.groups.count, "Gruppe", "Gruppen")) · \(plural(model.duplicateCount, "Duplikat", "Duplikate")) · "
                + "\(model.suggestedBytes.formattedBytes) freigebbar · \(plural(model.scannedCount, "Bild", "Bilder")) durchsucht"
        }
        if let trash = model.lastTrash {
            undoLabel.stringValue = "\(plural(trash.moves.count, "Datei", "Dateien")) im Papierkorb (\(trash.bytes.formattedBytes))"
            undoLabel.isHidden = false
            undoButton.isHidden = false
        } else {
            undoLabel.isHidden = true
            undoButton.isHidden = true
        }

        let count = model.marked.count
        markedLabel.stringValue = count == 0 ? "Nichts markiert" : "\(plural(count, "Datei", "Dateien")) markiert · \(model.markedBytes.formattedBytes)"
        markedLabel.textColor = count == 0 ? .secondaryLabelColor : .labelColor
        selectionButton.isEnabled = !model.groups.isEmpty
        trashButton.isEnabled = count > 0 && !model.isTrashing
        trashButton.title = model.isTrashing ? "Verschiebe …" : "In den Papierkorb …"
    }

    private func updateWindowSubtitle() {
        view.window?.subtitle = model.folder?.lastPathComponent ?? ""
    }

    private func refreshVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            if let item = collectionView.item(at: indexPath) as? PhotoItem {
                configure(item, at: indexPath)
            }
        }
        let kind = NSCollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            if let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? GroupHeaderView {
                configure(header, section: indexPath.section)
            }
        }
    }

    fileprivate func configure(_ item: PhotoItem, at indexPath: IndexPath) {
        let group = model.groups[indexPath.section]
        let file = group.files[indexPath.item]
        item.card.configure(file: file, folderText: folderText(for: file.url),
                            isMarked: model.marked.contains(file.url), role: group.roles[file.url],
                            closedEyes: group.closedEyes.contains(file.url), blurry: group.blurry.contains(file.url))
        item.card.onClick = { [weak self] clickCount in
            guard let self else { return }
            // Der erste Klick eines Doppelklicks hat schon umgeschaltet – zurücknehmen und öffnen.
            self.model.toggle(file.url)
            if clickCount == 2 { NSWorkspace.shared.open(file.url) }
        }
        item.card.menuProvider = { [weak self] in self?.contextMenu(for: file) }
    }

    fileprivate func configure(_ header: GroupHeaderView, section: Int) {
        let group = model.groups[section]
        header.configure(number: section + 1, group: group,
                         markedCount: group.files.filter { model.marked.contains($0.url) }.count)
        header.onApplySuggestion = { [weak self] in self?.model.applySuggestion(group: section) }
        header.onKeepAll = { [weak self] in self?.model.keepAll(group: section) }
    }

    /// Ordner der Datei relativ zum verknüpften Ordner, z. B. „Urlaub/2023“.
    private func folderText(for url: URL) -> String {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        if directory == rootPath { return "📁 Hauptordner" }
        if directory.hasPrefix(rootPath + "/") { return "📁 " + String(directory.dropFirst(rootPath.count + 1)) }
        return "📁 " + directory
    }

    private func contextMenu(for file: PhotoFile) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Öffnen") { NSWorkspace.shared.open(file.url) })
        menu.addItem(ActionMenuItem("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([file.url] + file.companions) })
        menu.addItem(.separator())
        let isMarked = model.marked.contains(file.url)
        menu.addItem(ActionMenuItem(isMarked ? "Behalten" : "Zum Löschen markieren") { [weak self] in self?.model.toggle(file.url) })
        menu.addItem(.separator())
        let directory = file.url.deletingLastPathComponent()
        let name = directory.lastPathComponent
        menu.addItem(ActionMenuItem("Fotos aus „\(name)“ bevorzugt behalten") { [weak self] in self?.model.prefer(folder: directory) })
        menu.addItem(ActionMenuItem("Alle Duplikate in „\(name)“ markieren") { [weak self] in self?.model.markDuplicates(inFolder: directory) })
        return menu
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hinweis"
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func useFolder(_ url: URL) {
        guard model.phase != .scanning else { return }
        model.setFolder(url)
        model.startScan()
    }

    // MARK: - Aktionen

    @objc func chooseFolder(_ sender: Any?) {
        guard model.phase != .scanning, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Verknüpfen"
        panel.message = "Wähle den Ordner mit deinen Fotos"
        panel.directoryURL = model.folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.useFolder(url)
        }
    }

    @objc func startScan(_ sender: Any?) { model.startScan() }
    @objc func cancelScan(_ sender: Any?) { model.cancelScan() }
    @objc func applySuggestions(_ sender: Any?) { model.applySuggestions() }
    @objc func clearMarks(_ sender: Any?) { model.clearMarks() }
    @objc func undoTrash(_ sender: Any?) { model.undoTrash() }
    @objc func clearScanCache(_ sender: Any?) { model.clearScanCache() }

    @objc private func scanOrCancel() {
        model.phase == .scanning ? model.cancelScan() : model.startScan()
    }

    @objc private func revealFolder() {
        guard let folder = model.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    @objc private func subfoldersChanged() {
        model.includeSubfolders = subfolderCheckbox.state == .on
    }

    @objc private func rawPairsChanged() {
        model.pairRawWithJPEG = rawPairCheckbox.state == .on
    }

    @objc private func optionsEdited() {
        var options = model.options
        options.identical = identicalCheckbox.state == .on
        options.compressed = compressedCheckbox.state == .on
        options.motif = motifCheckbox.state == .on
        options.minimumMotifSize = minimumSizeButton.selectedTag()
        options.tolerance = toleranceSlider.integerValue
        toleranceValueLabel.stringValue = "\(options.tolerance)"
        model.options = options
    }

    /// „PhotoHub sucht nach bytegleichen Kopien, komprimierten Kopien und gleichen Motiven (ab 3 Aufnahmen).“
    private func searchDescription() -> String {
        let options = model.options
        var parts: [String] = []
        if options.identical { parts.append("bytegleichen Kopien") }
        if options.compressed { parts.append("komprimierten Kopien (z. B. von WhatsApp)") }
        if options.motif { parts.append("gleichen Motiven (ab \(options.minimumMotifSize) Aufnahmen)") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " und " + parts.last! : parts.joined()
        var text = "PhotoHub sucht nach \(list)."
        if options.needsImageAnalysis { text += " Dafür wird jedes Bild einmal analysiert – bei späteren Scans nur noch neue und geänderte." }
        return text
    }

    @objc func confirmTrash(_ sender: Any?) {
        let files = model.markedFiles
        guard !files.isEmpty, !model.isTrashing, let window = view.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let companions = model.markedCompanionCount
        alert.messageText = "\(plural(files.count, "Foto", "Fotos"))"
            + (companions > 0 ? " und \(plural(companions, "Begleitdatei", "Begleitdateien"))" : "")
            + " in den Papierkorb verschieben?"
        var text = "Insgesamt \(model.markedBytes.formattedBytes). Mit „Rückgängig“ oder aus dem Papierkorb kannst du sie wiederherstellen."
        let fullyMarked = model.fullyMarkedGroupCount
        if fullyMarked > 0 {
            text = "Achtung: In \(plural(fullyMarked, "Gruppe", "Gruppen")) sind alle Dateien markiert – davon bleibt keine Kopie übrig.\n\n" + text
        }
        alert.informativeText = text
        alert.addButton(withTitle: "In den Papierkorb").hasDestructiveAction = true
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.trashMarked() }
        }
    }
}

// MARK: - Datenquelle

extension MainViewController: NSCollectionViewDataSource {
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        model.phase == .done ? model.groups.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.groups[section].files.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoItem.identifier, for: indexPath)
        if let item = item as? PhotoItem { configure(item, at: indexPath) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GroupHeaderView.identifier, for: indexPath)
        if let header = view as? GroupHeaderView { configure(header, section: indexPath.section) }
        return view
    }
}

// MARK: - Menüs aktivieren/deaktivieren

extension MainViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // In den anderen Tabs ist diese Ansicht nicht im Fenster – ihre Befehle gelten dann nicht.
        guard view.window != nil else { return false }
        switch menuItem.action {
        case #selector(chooseFolder(_:)): return model.phase != .scanning
        case #selector(startScan(_:)): return model.folder != nil && model.phase != .scanning
        case #selector(cancelScan(_:)): return model.phase == .scanning
        case #selector(confirmTrash(_:)): return !model.marked.isEmpty && !model.isTrashing
        case #selector(applySuggestions(_:)), #selector(clearMarks(_:)): return !model.groups.isEmpty
        case #selector(undoTrash(_:)): return model.lastTrash != nil && !model.isTrashing
        case #selector(clearScanCache(_:)):
            let size = ScanCache.shared.fileSize
            menuItem.title = size.map { "Scan-Cache leeren (\($0.formattedBytes))" } ?? "Scan-Cache leeren"
            return size != nil && model.phase != .scanning
        default: return true
        }
    }
}
