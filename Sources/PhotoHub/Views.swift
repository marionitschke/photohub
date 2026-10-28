import AppKit

// MARK: - Fotokarte

final class PhotoItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoItem")

    let card = PhotoCardView()

    override func loadView() {
        view = card
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.resetForReuse()
    }
}

/// Eine Kachel pro Datei. Klick schaltet zwischen „Behalten“ und „Löschen“ um, Doppelklick öffnet das Foto.
final class PhotoCardView: NSView {
    static let size = NSSize(width: 200, height: 262)

    var onClick: ((Int) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let thumbnailView = NSImageView()
    private let roleBadge = PillView(text: "", color: .systemBlue)
    /// „Augen zu“ und/oder „Unscharf“.
    private let hintBadge = PillView(text: "", color: .systemPink)
    private let nameLabel = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let statusPill = PillView(text: "", color: .systemGreen)
    private var isMarked = false
    private var url: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            thumbnailView.setContentCompressionResistancePriority(.defaultLow, for: orientation)
            thumbnailView.setContentHuggingPriority(.defaultLow, for: orientation)
        }

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.lineBreakMode = .byTruncatingHead
        for label in [folderLabel, infoLabel, dateLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        infoLabel.lineBreakMode = .byTruncatingTail
        dateLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [thumbnailView, nameLabel, folderLabel, infoLabel, dateLabel, statusPill])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(8, after: thumbnailView)
        stack.setCustomSpacing(8, after: dateLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(roleBadge)
        addSubview(hintBadge)

        var constraints = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            thumbnailView.heightAnchor.constraint(equalToConstant: 140),
            roleBadge.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 6),
            roleBadge.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: 6),
            hintBadge.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 6),
            hintBadge.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -6),
        ]
        for view in [thumbnailView, nameLabel, folderLabel, infoLabel, dateLabel] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    func configure(file: PhotoFile, folderText: String, isMarked: Bool, role: PhotoRole?, closedEyes: Bool, blurry: Bool) {
        if url != file.url {
            url = file.url
            thumbnailView.image = nil
            let requested = file.url
            ThumbnailLoader.shared.load(requested) { [weak self] image in
                guard let self, self.url == requested else { return }
                self.thumbnailView.image = image ?? NSWorkspace.shared.icon(forFile: requested.path)
            }
        }
        nameLabel.stringValue = [file.name, file.companionSummary].compactMap { $0 }.joined(separator: "  ")
        folderLabel.stringValue = folderText
        infoLabel.stringValue = [file.size.formattedBytes, file.dimensionsText].compactMap { $0 }.joined(separator: " · ")
        if let date = file.captureDate {
            dateLabel.stringValue = "Aufgenommen \(date.formatted(date: .numeric, time: .shortened))"
        } else if let date = file.created {
            dateLabel.stringValue = "Erstellt \(date.formatted(date: .numeric, time: .shortened))"
        } else {
            dateLabel.stringValue = " "
        }
        switch (closedEyes, blurry) {
        case (true, true): hintBadge.set(text: "Augen zu · unscharf", color: .systemPink)
        case (true, false): hintBadge.set(text: "Augen zu", color: .systemPink)
        case (false, true): hintBadge.set(text: "Unscharf", color: .systemPurple)
        case (false, false): break
        }
        hintBadge.isHidden = !closedEyes && !blurry
        hintBadge.toolTip = [closedEyes ? "Auf diesem Foto hat mindestens eine Person die Augen geschlossen." : nil,
                             blurry ? "Deutlich unschärfer als die schärfste Aufnahme dieses Motivs." : nil]
            .compactMap { $0 }.joined(separator: "\n")
        if let badge = role.map(Self.badge) {
            roleBadge.set(text: badge.text, color: badge.color)
            roleBadge.toolTip = badge.help
            roleBadge.isHidden = false
        } else {
            roleBadge.isHidden = true
        }
        self.isMarked = isMarked
        statusPill.set(text: isMarked ? "Löschen" : "Behalten", color: isMarked ? .systemRed : .systemGreen)
        thumbnailView.alphaValue = isMarked ? 0.4 : 1
        toolTip = ([file.url.path] + file.companions.map { "+ " + $0.lastPathComponent }).joined(separator: "\n")
        needsDisplay = true
    }

    private static func badge(for role: PhotoRole) -> (text: String, color: NSColor, help: String) {
        switch role {
        case .best:
            return ("Bestes", .systemBlue, "Empfohlen zum Behalten: höchste Auflösung, größte Datei, ältestes Original – "
                    + "bei gleichem Motiv die schärfste Aufnahme, auf der niemand die Augen zu hat")
        case .identicalCopy:
            return ("Bytegleich", .systemGray, "Byte für Byte gleiche Kopie")
        case .compressed:
            return ("Komprimiert", .systemOrange, "Dasselbe Foto in schlechterer Qualität (kleiner oder stärker komprimiert)")
        case .sameMotif:
            return ("Gleiches Motiv", .systemTeal, "Andere Aufnahme mit gleichem Bildaufbau und gleicher Qualität")
        }
    }

    func resetForReuse() {
        url = nil
        thumbnailView.image = nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isMarked ? NSColor.systemRed.withAlphaComponent(0.10) : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = (isMarked ? NSColor.systemRed : NSColor.separatorColor).cgColor
        layer?.borderWidth = isMarked ? 2 : 1
        thumbnailView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    // Die ganze Kachel reagiert auf Klicks, nicht nur einzelne Unteransichten.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

// MARK: - Gruppenüberschrift

final class GroupHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeader")

    var onApplySuggestion: (() -> Void)?
    var onKeepAll: (() -> Void)?

    private let separator = NSBox()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "⚠︎ Alle markiert – keine Kopie bleibt übrig")
    private lazy var autoButton = NSButton(title: "Vorschlag", target: self, action: #selector(applySuggestionClicked))
    private lazy var keepButton = NSButton(title: "Alle behalten", target: self, action: #selector(keepAllClicked))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        warningLabel.font = .systemFont(ofSize: 12, weight: .medium)
        warningLabel.textColor = .systemOrange
        autoButton.toolTip = "Markierungen dieser Gruppe auf den Vorschlag zurücksetzen"
        keepButton.toolTip = "Keine Datei dieser Gruppe löschen"
        for button in [autoButton, keepButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [titleLabel, detailLabel, warningLabel, spacer, autoButton, keepButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    func configure(number: Int, group: DuplicateGroup, markedCount: Int) {
        separator.isHidden = number == 1
        titleLabel.stringValue = "\(number.formatted()). \(group.title)"
        var details = plural(group.files.count, "Datei", "Dateien")
        if group.suggestedBytes > 0 { details += " · \(group.suggestedBytes.formattedBytes) freigebbar" }
        if markedCount > 0 { details += " · \(markedCount.formatted()) markiert" }
        detailLabel.stringValue = details
        warningLabel.isHidden = markedCount < group.files.count
    }

    @objc private func applySuggestionClicked() { onApplySuggestion?() }
    @objc private func keepAllClicked() { onKeepAll?() }
}

// MARK: - Kleine Bausteine

/// Farbige Plakette mit weißem Text („Behalten“, „Löschen“, „Bestes“).
final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var color: NSColor

    init(text: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    func set(text: String, color: NSColor) {
        label.stringValue = text
        self.color = color
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = bounds.height / 2
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// Zentrierter Hinweis mit Symbol, Überschrift, Text und optionalem Button.
final class MessageView: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var button = NSButton(title: "", target: self, action: #selector(buttonClicked))
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.symbolConfiguration = .init(pointSize: 52, weight: .light)
        imageView.contentTintColor = .tertiaryLabelColor
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .secondaryLabelColor
        textLabel.alignment = .center
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [imageView, titleLabel, textLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: imageView)
        stack.setCustomSpacing(20, after: textLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    func show(symbol: String, title: String, text: String, buttonTitle: String? = nil, action: (() -> Void)? = nil) {
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        titleLabel.stringValue = title
        textLabel.stringValue = text
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        self.action = action
    }

    @objc private func buttonClicked() { action?() }
}

/// Fortschrittsanzeige während des Scans.
final class ScanProgressView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let indicator = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        indicator.style = .bar
        indicator.isIndeterminate = true

        let stack = NSStackView(views: [titleLabel, indicator, detailLabel, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            indicator.widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    func update(_ progress: ScanProgress) {
        titleLabel.stringValue = progress.message
        if progress.total > 0 {
            indicator.stopAnimation(nil)
            indicator.isIndeterminate = false
            indicator.maxValue = Double(progress.total)
            indicator.doubleValue = Double(progress.done)
            detailLabel.stringValue = "\(progress.done.formatted()) von \(progress.total.formatted())"
        } else {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
            detailLabel.stringValue = progress.done > 0 ? "\(plural(progress.done, "Bild", "Bilder")) gefunden" : " "
        }
    }
}

/// Wurzelansicht des Fensters: nimmt per Drag & Drop einen Ordner an.
final class DropView: NSView {
    var onDropFolder: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    private func folderURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let url = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folderURL(from: sender) == nil ? [] : .link
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = folderURL(from: sender) else { return false }
        onDropFolder?(url)
        return true
    }
}

/// Menüeintrag, der eine Closure ausführt.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    @objc private func run() { handler() }
}
