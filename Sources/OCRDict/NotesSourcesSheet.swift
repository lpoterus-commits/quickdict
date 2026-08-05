import AppKit

/// 本地资料清单。
///
/// 「添加词典」那套通用表单是为网页词典设计的：填个网址就完了。本地资料不一样 ——
/// 它是**一份清单**，会增会减，而且常常分好几份。为它单开一个界面才合适。
///
/// 除了选文件、选文件夹，这里还能**直接把文件拖进来**。这一条不只是方便：
/// 系统的文件选择框会把某些 `.md` 显示成灰色选不中（权限齐全、App 也读得到，
/// 但面板就是不让选，原因在 App 这边查不出来）。拖放不经过那个面板，绕开了它。
final class NotesSourcesSheetController: NSObject {

    private var sheet: NSWindow!
    private var rowsStack: NSStackView!
    private var nameField: NSTextField!
    private var summaryLabel: NSTextField!

    private var paths: [String] = []
    private var editing: DictSite?
    private var existingIDs: Set<String> = []
    private var done: ((DictSite) -> Void)?

    func present(in parent: NSWindow, editing site: DictSite?,
                 existingIDs ids: Set<String>, done handler: @escaping (DictSite) -> Void) {
        editing = site
        existingIDs = ids
        done = handler
        paths = site?.notes ?? site.flatMap { s -> [String] in
            guard let url = URL(string: s.url), url.isFileURL else { return [] }
            return [url.path]
        } ?? []

        build()
        nameField.stringValue = site?.name ?? t("notes.defaultName")
        rebuildRows()
        parent.beginSheet(sheet)
    }

    // MARK: - 构建

    private func build() {
        let title = NSTextField(labelWithString: t("notes.sheetTitle"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let lead = NSTextField(wrappingLabelWithString: t("notes.sheetLead"))
        lead.font = .systemFont(ofSize: 11)
        lead.textColor = .secondaryLabelColor

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedContainer()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 6),
            rowsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 10),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: clip.bottomAnchor),
        ])

        let drop = DropWell()
        drop.onDrop = { [weak self] urls in self?.add(urls) }
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: drop.topAnchor),
            clip.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: drop.bottomAnchor),
        ])

        summaryLabel = NSTextField(wrappingLabelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor

        let pickFiles = NSButton(title: t("notes.pickFiles"), target: self, action: #selector(chooseFiles))
        pickFiles.bezelStyle = .rounded
        let pickFolder = NSButton(title: t("notes.pickFolder"), target: self, action: #selector(chooseFolder))
        pickFolder.bezelStyle = .rounded
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let cancel = NSButton(title: t("keys.cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: t("keys.save"), target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        let buttons = NSStackView(views: [pickFiles, pickFolder, gap, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let nameLabel = NSTextField(labelWithString: t("sheet.name"))
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameField = NSTextField(string: "")
        let nameRow = NSStackView(views: [nameLabel, nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 10

        let stack = NSStackView(views: [title, lead, drop, summaryLabel, nameRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(stack)
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset),
            drop.heightAnchor.constraint(equalToConstant: 190),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset),
            lead.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset),
            summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset),
            nameField.widthAnchor.constraint(equalToConstant: 280),
        ])

        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                         styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = host
        sheet.isReleasedWhenClosed = false
    }

    // MARK: - 清单

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        if paths.isEmpty {
            let empty = NSTextField(labelWithString: t("notes.dropHere"))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            rowsStack.addArrangedSubview(empty)
        } else {
            for index in paths.indices { rowsStack.addArrangedSubview(makeRow(index)) }
        }
        updateSummary()
    }

    private func makeRow(_ index: Int) -> NSView {
        let url = URL(fileURLWithPath: paths[index])
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        // 原件不在不等于用不了 —— 副本库里可能还留着
        let missing = NotesLibrary.markdownFiles(at: url.path).isEmpty

        let icon = NSTextField(labelWithString: missing ? "🗄" : (isDirectory.boolValue ? "📁" : "📄"))
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 12)
        name.textColor = missing ? .systemOrange : .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = url.path
        name.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let kind = NSTextField(labelWithString: missing ? t("notes.usingCopy")
                                                       : (isDirectory.boolValue ? t("notes.kindFolder")
                                                                                : t("notes.kindFile")))
        kind.font = .systemFont(ofSize: 11)
        kind.textColor = .secondaryLabelColor
        kind.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let remove = NSButton(title: "✕", target: self, action: #selector(removeRow(_:)))
        remove.bezelStyle = .inline
        remove.tag = index
        remove.toolTip = t("keys.delete")

        let row = NSStackView(views: [icon, name, kind, remove])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    /// 一眼能看到「一共会收进来多少条」，省得保存完才发现路径写错
    private func updateSummary() {
        guard !paths.isEmpty else {
            summaryLabel.stringValue = ""
            return
        }
        let files = NotesLibrary.resolve(sources: paths).map(\.path)
        summaryLabel.stringValue = files.isEmpty
            ? t("notes.summaryNone")
            : t("notes.summary", paths.count, files.count)
        summaryLabel.textColor = files.isEmpty ? .systemOrange : .secondaryLabelColor
    }

    private func add(_ urls: [URL]) {
        for url in urls where !paths.contains(url.path) { paths.append(url.path) }
        rebuildRows()
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard paths.indices.contains(sender.tag) else { return }
        paths.remove(at: sender.tag)
        rebuildRows()
    }

    @objc private func chooseFiles() { pick(directories: false) }
    @objc private func chooseFolder() { pick(directories: true) }

    private func pick(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = true
        panel.message = directories ? t("notes.pickFolderPrompt") : t("sheet.filePrompt")
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }

    // MARK: - 完成

    @objc private func cancel() { sheet.sheetParent?.endSheet(sheet) }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { flash(t("sheet.errName")); return }
        guard !paths.isEmpty else { flash(t("notes.errEmpty")); return }

        let id = editing?.id ?? {
            var n = 1
            while existingIDs.contains("notes\(n)") { n += 1 }
            return "notes\(n)"
        }()
        // url 留一个指向第一项的形式，好让不认识 notes 字段的旧版本也能读出点东西
        let encoded = paths[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? paths[0]
        let site = DictSite(id: id, name: name, languages: editing?.languages ?? [],
                            url: "file://\(encoded)?q={q}", suffix: nil, external: nil,
                            notes: paths)
        sheet.sheetParent?.endSheet(sheet)
        done?(site)
    }

    private func flash(_ message: String) {
        summaryLabel.stringValue = message
        summaryLabel.textColor = .systemOrange
        NSSound.beep()
    }
}

/// 能接住拖进来的文件的区域
private final class DropWell: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                     : NSColor.textBackgroundColor).setFill()
        path.fill()
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = highlighted ? 2 : 1
        if !highlighted { path.setLineDash([4, 3], count: 2, phase: 0) }
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
