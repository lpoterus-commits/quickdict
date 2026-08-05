import AppKit

/// 添加 / 更改一条词典的表单。
///
/// 原先这一步是让人往表格里手打网址 —— 得知道 `{q}` 是什么、得把本地文件的路径
/// 一个字不差敲对。对不写代码的人，那等于没有这个功能。
///
/// 这里把它拆成「先选一种来源，再填一格」：常用词典是从清单里挑，本地文件是弹
/// 文件选择框，本地词典 App 是从装了的里面挑。只有「自己填网址」才需要碰 `{q}`，
/// 而那是留给确实想自定义的人的。
final class DictionarySheetController: NSObject {

    enum Kind: Int, CaseIterable {
        case preset      // 从常用词典里挑
        case file        // 本地文件
        case app         // 本地词典 App
        case custom      // 自己填网址
    }

    private var sheet: NSWindow!
    private var kindButtons: [NSButton] = []
    private var presetPopup: NSPopUpButton!
    private var appPopup: NSPopUpButton!
    private var fileButton: NSButton!
    private var fileLabel: NSTextField!
    private var customField: NSTextField!
    private var customHint: NSTextField!
    private var nameField: NSTextField!
    private var errorLabel: NSTextField!

    private var presets: [DictSite] = []
    private var apps: [LocalDictionaries.Entry] = []
    private var pickedFiles: [URL] = []
    private var editing: DictSite?
    private var existingIDs: Set<String> = []
    private var done: ((DictSite) -> Void)?

    /// - Parameter editing: nil 表示新增
    func present(in parent: NSWindow, config: AppConfig, editing site: DictSite?,
                 existingIDs ids: Set<String>, done handler: @escaping (DictSite) -> Void) {
        editing = site
        existingIDs = ids
        done = handler
        presets = DictionaryPresets.catalog(target: config.dictionaryLanguage)
        apps = LocalDictionaries.installed

        build()
        prefill(site)
        parent.beginSheet(sheet)
    }

    // MARK: - 构建

    private func build() {
        let title = NSTextField(labelWithString: editing == nil ? t("sheet.addTitle") : t("sheet.editTitle"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let kindLabel = NSTextField(labelWithString: t("sheet.kind"))
        kindLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        kindLabel.textColor = .secondaryLabelColor

        // ── 四种来源，各自一行：单选钮 + 它自己的控件
        let titles = [t("sheet.kindPreset"), t("sheet.kindFile"), t("sheet.kindApp"), t("sheet.kindCustom")]
        kindButtons = titles.enumerated().map { index, text in
            let b = NSButton(radioButtonWithTitle: text, target: self, action: #selector(kindChanged))
            b.tag = index
            b.widthAnchor.constraint(equalToConstant: 130).isActive = true
            return b
        }

        presetPopup = NSPopUpButton()
        presets.forEach { presetPopup.addItem(withTitle: $0.name) }
        presetPopup.target = self
        presetPopup.action = #selector(presetPicked)

        fileButton = NSButton(title: t("sheet.chooseFile"), target: self, action: #selector(chooseFile))
        fileButton.bezelStyle = .rounded
        fileLabel = NSTextField(labelWithString: t("sheet.noFile"))
        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle

        appPopup = NSPopUpButton()
        if apps.isEmpty {
            appPopup.addItem(withTitle: t("sheet.noApps"))
            appPopup.isEnabled = false
            kindButtons[Kind.app.rawValue].isEnabled = false
        } else {
            apps.forEach { appPopup.addItem(withTitle: $0.name) }
        }

        customField = NSTextField(string: "")
        customField.placeholderString = "https://example.com/search?q={q}"
        customField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        customHint = NSTextField(wrappingLabelWithString: t("sheet.customHint"))
        customHint.font = .systemFont(ofSize: 11)
        customHint.textColor = .secondaryLabelColor

        let rows = NSStackView(views: [
            row(kindButtons[0], presetPopup, stretch: presetPopup),
            row(kindButtons[1], fileButton, fileLabel, stretch: fileLabel),
            row(kindButtons[2], appPopup, stretch: appPopup),
            row(kindButtons[3], customField, stretch: customField),
            row(spacer(130), customHint, stretch: customHint),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10

        // ── 名称
        let nameLabel = NSTextField(labelWithString: t("sheet.name"))
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameField = NSTextField(string: "")
        nameField.placeholderString = t("sheet.namePlaceholder")

        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemOrange

        let cancel = NSButton(title: t("keys.cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: editing == nil ? t("sheet.add") : t("keys.save"),
                               target: self, action: #selector(confirm))
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [gap, cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, kindLabel, rows, nameLabel, nameField,
                                        errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: rows)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 300),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                           constant: -(stack.edgeInsets.left + stack.edgeInsets.right)),
            errorLabel.widthAnchor.constraint(equalToConstant: 480),
        ])

        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                         styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = host
        sheet.isReleasedWhenClosed = false
    }

    private func row(_ views: NSView..., stretch: NSView) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        stretch.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return s
    }

    private func spacer(_ width: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    // MARK: - 状态

    private func prefill(_ site: DictSite?) {
        guard let site else {
            select(.preset)
            presetPicked()
            return
        }
        nameField.stringValue = site.name
        switch inferKind(site.url) {
        case .file:
            select(.file)
            // 清单优先；没有清单的旧配置回落到 url 里那一个路径
            let paths = site.notes ?? (URL(string: site.url)?.path).map { [$0] } ?? []
            pickedFiles = paths.map { URL(fileURLWithPath: $0) }
            showPickedFiles()
        case .app:
            select(.app)
            if let index = apps.firstIndex(where: { site.url.hasPrefix("\($0.scheme):") }) {
                appPopup.selectItem(at: index)
            }
        default:
            // 命中预设就停在预设，否则当自定义处理
            if let index = presets.firstIndex(where: { $0.url == site.url }) {
                select(.preset)
                presetPopup.selectItem(at: index)
            } else {
                select(.custom)
                customField.stringValue = site.url
            }
        }
    }

    private func inferKind(_ url: String) -> Kind {
        if url.hasPrefix("file://") { return .file }
        if let scheme = URL(string: url)?.scheme, scheme != "http", scheme != "https" { return .app }
        return .custom
    }

    private var kind: Kind {
        Kind(rawValue: kindButtons.firstIndex { $0.state == .on } ?? 0) ?? .preset
    }

    private func select(_ k: Kind) {
        kindButtons.forEach { $0.state = $0.tag == k.rawValue ? .on : .off }
        refreshEnabled()
    }

    private func refreshEnabled() {
        let k = kind
        presetPopup.isEnabled = k == .preset
        fileButton.isEnabled = k == .file
        appPopup.isEnabled = k == .app && !apps.isEmpty
        customField.isEnabled = k == .custom
        customHint.textColor = k == .custom ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func kindChanged(_ sender: NSButton) {
        select(Kind(rawValue: sender.tag) ?? .preset)
        // 换来源时，名字如果还是上一种自动填的，跟着换掉
        switch kind {
        case .preset: presetPicked()
        case .app: if nameField.stringValue.isEmpty, let e = currentApp { nameField.stringValue = e.name }
        default: break
        }
    }

    @objc private func presetPicked() {
        guard kind == .preset, presets.indices.contains(presetPopup.indexOfSelectedItem) else { return }
        nameField.stringValue = presets[presetPopup.indexOfSelectedItem].name
    }

    private var currentApp: LocalDictionaries.Entry? {
        guard !apps.isEmpty, apps.indices.contains(appPopup.indexOfSelectedItem) else { return nil }
        return apps[appPopup.indexOfSelectedItem]
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        // 笔记常常是分好几份的，一次能挑几份才合理 —— 它们合成同一本词典
        panel.allowsMultipleSelection = true
        // 不做类型过滤。按 UTType 过滤会把合法的 .md 变灰选不中 —— 同一个文件夹里
        // 类型完全相同的文件，有的能选有的不能，判定不可复现。
        // 挑错了文件不会有坏后果：解析不出条目会显示提示页，说明它看到了什么。
        panel.message = t("sheet.filePrompt")
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            self.pickedFiles = panel.urls
            self.showPickedFiles()
            if self.nameField.stringValue.isEmpty, let first = panel.urls.first {
                self.nameField.stringValue = panel.urls.count == 1
                    ? first.deletingPathExtension().lastPathComponent
                    : first.deletingLastPathComponent().lastPathComponent
            }
        }
    }

    private func showPickedFiles() {
        switch pickedFiles.count {
        case 0: fileLabel.stringValue = t("sheet.noFile")
        case 1: fileLabel.stringValue = pickedFiles[0].lastPathComponent
        default: fileLabel.stringValue = t("sheet.filesPicked", pickedFiles.count)
        }
        fileLabel.toolTip = pickedFiles.map(\.path).joined(separator: "\n")
    }

    // MARK: - 完成

    @objc private func cancel() {
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func confirm() {
        guard let built = buildSite() else { return }
        sheet.sheetParent?.endSheet(sheet)
        done?(built)
    }

    private func buildSite() -> DictSite? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)

        var url: String
        var external: Bool? = editing?.external
        var suffix: String? = editing?.suffix
        var noteList: [String]? = nil

        switch kind {
        case .preset:
            guard presets.indices.contains(presetPopup.indexOfSelectedItem) else {
                return fail(t("sheet.errPreset"))
            }
            let picked = presets[presetPopup.indexOfSelectedItem]
            url = picked.url
            external = picked.external
            suffix = picked.suffix

        case .file:
            guard let first = pickedFiles.first else { return fail(t("sheet.errFile")) }
            // 路径可能有中文和空格；查询串接在后面，页面自己从 ?q= 读
            guard var encoded = first.path.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed) else { return fail(t("sheet.errFile")) }
            encoded = encoded.replacingOccurrences(of: "?", with: "%3F")
            url = "file://\(encoded)?q={q}"
            external = nil
            // 几份资料合成一本词典，而不是各占一个标签
            noteList = pickedFiles.map(\.path)

        case .app:
            guard let entry = currentApp else { return fail(t("sheet.errApp")) }
            url = entry.urlTemplate
            external = true                     // 自定义 scheme 内嵌 WebView 加载不了

        case .custom:
            url = customField.stringValue.trimmingCharacters(in: .whitespaces)
            guard url.contains("{q}") else { return fail(t("sheet.errQ")) }
            guard URL(string: url) != nil || URL(string: url.replacingOccurrences(of: "{q}", with: "x")) != nil
            else { return fail(t("sheet.errURL")) }
        }

        guard !name.isEmpty else { return fail(t("sheet.errName")) }

        // 编辑时保留原 id（快捷键可能指着它）；新增时挑一个没被占用的
        let id: String
        if let editing { id = editing.id } else {
            var n = 1
            while existingIDs.contains("custom\(n)") { n += 1 }
            id = "custom\(n)"
        }
        return DictSite(id: id, name: name, languages: editing?.languages ?? [],
                        url: url, suffix: suffix, external: external, notes: noteList)
    }

    private func fail(_ message: String) -> DictSite? {
        errorLabel.stringValue = message
        NSSound.beep()
        return nil
    }
}
