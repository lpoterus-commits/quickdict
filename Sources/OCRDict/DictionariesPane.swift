import AppKit

/// 词典设置窗口。
///
/// 这里刻意**不显示网址**。列表只回答两个问题：叫什么、去哪儿（「网页 · zh.dict.naver.com」
/// 「本地文件 · 我的语法笔记.md」）。要改就点「更改…」，在表单里选，不用手打 URL。
///
/// 命中语言同理 —— 原先要按格式手敲 `ko, zh`，现在是个勾选菜单。
final class DictionariesPane: NSObject, ShellPane {
    var paneTitle: String { t("menu.dictionaries") }

    private var contentView: NSView?
    private var rowsStack: NSStackView!
    private var statusLabel: NSTextField!

    private var sites: [DictSite] = []
    private var config: AppConfig = .fallback
    private var onSave: (([DictSite]) -> Void)?
    private var onReset: (() -> [DictSite])?
    private var sheetController: DictionarySheetController?
    private var notesSheet: NotesSourcesSheetController?
    /// 有没有还没保存的改动。**有的话切走再切回来不重新读配置** ——
    /// 独立窗口时代关掉就等于放弃，现在页是随手切的，改到一半切去查个词
    /// 回来发现全没了，那才是真的难用。
    private var dirty = false

    /// 出 sheet 要挂在窗口上，问外壳要
    var hostWindow: (() -> NSWindow?)?

    /// 启动时装一次回调。数据每次切过来再从配置读（见 paneWillAppear）。
    func configure(onReset: @escaping () -> [DictSite],
                   onSave: @escaping ([DictSite]) -> Void) {
        self.onSave = onSave
        self.onReset = onReset
    }

    func paneWillAppear(config cfg: AppConfig) {
        config = cfg
        guard !dirty else { return }
        sites = cfg.dictionaries
        rebuildRows()
        status(t("dict.hint"), warning: false)
    }

    // MARK: - 构建

    func makePaneView() -> NSView {
        if let contentView { return contentView }

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 7
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedContainer()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
            rowsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -4),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = clip
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: t("dict.add"), target: self, action: #selector(addSite))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "n"
        addButton.keyEquivalentModifierMask = .command
        let notesButton = NSButton(title: t("dict.addNotes"), target: self, action: #selector(addNotes))
        notesButton.bezelStyle = .rounded
        notesButton.toolTip = t("dict.addNotes.tip")
        let resetButton = NSButton(title: t("dict.reset"), target: self, action: #selector(resetSites))
        resetButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let cancelButton = NSButton(title: t("keys.cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: t("keys.save"), target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonBar = NSStackView(views: [addButton, notesButton, resetButton, spacer,
                                           cancelButton, saveButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(wrappingLabelWithString: t("dict.hint"))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let content = NSView()
        for v in [header, scroll, statusLabel, buttonBar] as [NSView] { content.addSubview(v) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -10),

            buttonBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttonBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        contentView = content
        return content
    }

    private func makeHeader() -> NSStackView {
        func label(_ text: String, _ width: CGFloat) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: 11, weight: .semibold)
            f.textColor = .secondaryLabelColor
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
            return f
        }
        let stack = NSStackView(views: [label(t("dict.colName"), 150),
                                        label(t("dict.colTarget"), 272),
                                        label(t("dict.colLanguages"), 150)])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        for index in sites.indices { rowsStack.addArrangedSubview(makeRow(index)) }
    }

    private func makeRow(_ index: Int) -> NSView {
        let site = sites[index]

        let name = NSTextField(string: site.name)
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        name.tag = index
        name.delegate = self

        // 网址不直接显示 —— 一行读得懂的摘要 + 一个「更改…」按钮
        let target = NSTextField(labelWithString: Self.summary(site))
        target.font = .systemFont(ofSize: 12)
        target.textColor = .secondaryLabelColor
        target.lineBreakMode = .byTruncatingMiddle
        target.toolTip = site.url
        target.widthAnchor.constraint(equalToConstant: 192).isActive = true

        let change = NSButton(title: t("dict.change"), target: self, action: #selector(changeSite(_:)))
        change.bezelStyle = .rounded
        change.tag = index
        change.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let langs = NSPopUpButton()
        langs.pullsDown = true
        langs.tag = index
        buildLanguageMenu(langs, site: site, index: index)
        langs.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let remove = NSButton(title: "✕", target: self, action: #selector(removeSite(_:)))
        remove.bezelStyle = .rounded
        remove.tag = index
        remove.toolTip = t("keys.delete")

        let row = NSStackView(views: [name, target, change, langs, remove])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    /// 「网页 · zh.dict.naver.com」这样的一句话，代替裸网址
    static func summary(_ site: DictSite) -> String {
        if site.isDatabase, let path = site.localPath {
            return t("dict.sum.db", URL(fileURLWithPath: path).lastPathComponent)
        }
        if let notes = site.notes, notes.count > 1 {
            return t("dict.sum.files", notes.count)
        }
        if site.url.hasPrefix("file://") {
            let name = URL(string: site.url).map {
                URL(fileURLWithPath: $0.path).lastPathComponent
            } ?? site.url
            return t("dict.sum.file", name)
        }
        guard let url = URL(string: site.url.replacingOccurrences(of: "{q}", with: "x")),
              let scheme = url.scheme else { return site.url }
        if scheme != "http" && scheme != "https" {
            let name = LocalDictionaries.known.first { $0.scheme == scheme }?.name ?? scheme
            return t("dict.sum.app", name)
        }
        return t("dict.sum.web", url.host ?? site.url)
    }

    // MARK: - 命中语言（勾选，不用手打）

    private func buildLanguageMenu(_ button: NSPopUpButton, site: DictSite, index: Int) {
        let menu = NSMenu()
        // 下拉按钮的第一项显示为按钮标题本身，不参与选择
        menu.addItem(withTitle: languageSummary(site), action: nil, keyEquivalent: "")

        let manual = NSMenuItem(title: t("dict.langManual"), action: #selector(clearLanguages(_:)),
                                keyEquivalent: "")
        manual.target = self
        manual.tag = index
        manual.state = site.languages.isEmpty ? .on : .off
        menu.addItem(manual)

        let fallback = NSMenuItem(title: t("dict.langFallback"), action: #selector(toggleLanguage(_:)),
                                  keyEquivalent: "")
        fallback.target = self
        fallback.representedObject = LanguagePick(index: index, code: "*")
        fallback.state = site.languages.contains("*") ? .on : .off
        menu.addItem(fallback)
        menu.addItem(.separator())

        for code in DictionaryPresets.selectableSources {
            let item = NSMenuItem(title: LanguageNames.display(code),
                                  action: #selector(toggleLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = LanguagePick(index: index, code: code)
            item.state = site.languages.contains(code) ? .on : .off
            menu.addItem(item)
        }
        button.menu = menu
    }

    private struct LanguagePick { let index: Int; let code: String }

    private func languageSummary(_ site: DictSite) -> String {
        if site.languages.isEmpty { return t("dict.langManual") }
        if site.languages.contains("*") { return t("dict.langFallback") }
        return site.languages.map { LanguageNames.display($0) }.joined(separator: "、")
    }

    @objc private func toggleLanguage(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? LanguagePick,
              sites.indices.contains(pick.index) else { return }
        if let at = sites[pick.index].languages.firstIndex(of: pick.code) {
            sites[pick.index].languages.remove(at: at)
        } else {
            sites[pick.index].languages.append(pick.code)
        }
        rebuildRows()
    }

    @objc private func clearLanguages(_ sender: NSMenuItem) {
        guard sites.indices.contains(sender.tag) else { return }
        sites[sender.tag].languages = []
        rebuildRows()
    }

    // MARK: - 增删改

    @objc private func changeSite(_ sender: NSButton) {
        guard sites.indices.contains(sender.tag), let window = hostWindow?() else { return }
        commitFields()
        let index = sender.tag
        // 本地资料是一份清单，不是一个网址 —— 用它自己的界面改
        if sites[index].isNotes {
            editNotes(at: index, in: window)
            return
        }
        let controller = DictionarySheetController()
        sheetController = controller
        controller.present(in: window, config: config, editing: sites[index],
                           existingIDs: Set(sites.map(\.id))) { [weak self] updated in
            guard let self, self.sites.indices.contains(index) else { return }
            // 命中语言归列表管，表单不碰
            var merged = updated
            merged.languages = self.sites[index].languages
            self.sites[index] = merged
            self.rebuildRows()
        }
    }

    @objc private func addNotes() {
        guard let window = hostWindow?() else { return }
        commitFields()
        editNotes(at: nil, in: window)
    }

    private func editNotes(at index: Int?, in window: NSWindow) {
        let controller = NotesSourcesSheetController()
        notesSheet = controller
        controller.present(in: window, editing: index.map { sites[$0] },
                           existingIDs: Set(sites.map(\.id))) { [weak self] site in
            guard let self else { return }
            if let index, self.sites.indices.contains(index) {
                var merged = site
                merged.languages = self.sites[index].languages
                self.sites[index] = merged
            } else {
                self.sites.insert(site, at: 0)   // 放最前，⌘1 就能到
                self.status(t("dict.addedHint", site.name), warning: false)
            }
            self.rebuildRows()
        }
    }

    @objc private func addSite() {
        guard let window = hostWindow?() else { return }
        commitFields()
        let controller = DictionarySheetController()
        sheetController = controller
        controller.present(in: window, config: config, editing: nil,
                           existingIDs: Set(sites.map(\.id))) { [weak self] created in
            guard let self else { return }
            self.sites.append(created)
            self.rebuildRows()
            self.status(t("dict.addedHint", created.name), warning: false)
        }
    }

    @objc private func removeSite(_ sender: NSButton) {
        guard sites.indices.contains(sender.tag) else { return }
        commitFields()
        sites.remove(at: sender.tag)
        rebuildRows()
    }

    @objc private func resetSites() {
        guard let onReset else { return }
        sites = onReset()
        dirty = true
        rebuildRows()
        status(t("keys.resetHint"), warning: false)
    }

    /// 撤销还没保存的改动，回到配置里那一份。
    /// 页是关不掉的，所以「取消」在这里的意思从「关窗口」变成了「还原」。
    @objc private func cancel() {
        sites = config.dictionaries
        dirty = false
        rebuildRows()
        status(t("dict.reverted"), warning: false)
    }

    @objc private func save() {
        commitFields()
        if let problem = firstProblem() {
            status(problem, warning: true)
            NSSound.beep()
            return
        }
        onSave?(sites)
        dirty = false
        status(t("dict.saved"), warning: false)
    }

    /// 焦点还在名称框里时按保存，那一格的值还没提交，先抓出来
    private func commitFields() {
        for row in rowsStack.arrangedSubviews {
            guard let stack = row as? NSStackView else { continue }
            for view in stack.arrangedSubviews {
                if let field = view as? NSTextField, field.isEditable { apply(field) }
            }
        }
    }

    private func apply(_ field: NSTextField) {
        guard sites.indices.contains(field.tag) else { return }
        sites[field.tag].name = field.stringValue.trimmingCharacters(in: .whitespaces)
        dirty = true
    }

    private func firstProblem() -> String? {
        // 网址由表单保证格式，这里只剩名字要看
        sites.contains { $0.name.isEmpty } ? t("dict.needName") : nil
    }

    private func status(_ text: String, warning: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

}

extension DictionariesPane: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField { apply(field) }
    }
}

/// NSView 默认原点在左下，放进 NSScrollView 后内容会贴底。翻转坐标系让它从顶部排。
final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
