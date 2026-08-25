import AppKit

/// 主窗口 —— 这个 App 唯一的窗口。
///
/// ## 为什么从六个窗口收成一个
///
/// 3.1 之前：主页、查词浮窗、词典设置、快捷键设置、使用说明、设置向导，
/// 六个各自独立的 `NSWindow`。每个都要自己决定开在哪、自己管关闭，
/// 互相盖来盖去，而且**没有一个地方能一眼看全这个工具能干什么**。
///
/// 现在是标准的 macOS 三段式：
///
///     ┌──────────────────────────────────────┐
///     │ 工具栏：取词入口 + 查词框              │  ← 常用动作，随时能按
///     ├───────────┬──────────────────────────┤
///     │ 侧边栏     │                          │
///     │  主页      │        主显示区           │
///     │  查词      │                          │
///     │  语音      │   （切到哪一页显示哪页）   │
///     │  设置…     │                          │
///     └───────────┴──────────────────────────┘
///
/// 用 `NSSplitViewController` 而不是自己拿 `NSSplitView` 搭：侧边栏的毛玻璃质感、
/// 折叠动画、和工具栏的对齐（那条分隔线要正好接上侧边栏边缘）全是系统给的，
/// 手搭的话这些细节一个都对不上，一眼就能看出是「不像原生的 App」。
final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {

    private var window: MainWindow?
    private var split: NSSplitViewController?
    private var sidebar: SidebarViewController?
    private let contentHost = NSViewController()

    /// 已经建出来的页。第一次切到才建 —— 查词那页要连带起一个 WebView，不该白建。
    private var panes: [PaneID: ShellPane] = [:]
    private var built: Set<PaneID> = []
    private(set) var current: PaneID = .home

    private var config: AppConfig = .fallback

    /// 工具栏上那个查词框
    private var searchField: NSSearchField?

    // MARK: 对外的口子

    /// 工具栏上的取词按钮：screenshot / selection / clipboard / speak
    var onCapture: ((String) -> Void)?
    /// 工具栏查词框回车，或主页上点了查词
    var onLookup: ((String, String?) -> Void)?
    /// 页面里点了别的动作（onboarding / config / keepLogin …）
    var onRun: ((String) -> Void)?
    /// 换页了。快捷键设置那一页进出时要摘掉 / 装回全局热键 ——
    /// 不摘的话按 ⌃⌥9 会直接触发截图，根本录不进去。
    var onPaneChanged: ((PaneID?, PaneID) -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    /// 页要出 sheet（选文件、确认框）时挂在这上面
    var hostWindow: NSWindow? { window }

    // MARK: - 注册页

    func register(_ id: PaneID, _ pane: ShellPane) {
        panes[id] = pane
    }

    func pane(_ id: PaneID) -> ShellPane? { panes[id] }

    // MARK: - 显示

    func show(config: AppConfig, select id: PaneID? = nil) {
        self.config = config
        build()
        if let id { select(id) } else { refreshCurrent() }
        // accessory App 抢不到前台，弹出时先抬一层，失焦再沉回去（见 windowDidResignKey）
        window?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// 切到某一页。已经在这一页也会重新刷一遍 —— 权限、词典可能在别处改过。
    func select(_ id: PaneID) {
        guard panes[id] != nil else { return }
        let previous = current
        current = id
        sidebar?.select(id)
        showPane(id)
        if previous != id { onPaneChanged?(previous, id) }
    }

    /// 当前这页重新拉一次数据
    func refreshCurrent() {
        showPane(current)
    }

    func refresh(config: AppConfig) {
        self.config = config
        searchField?.placeholderString = t("home.placeholder")
        guard window != nil else { return }
        refreshCurrent()
    }

    /// 把查词框里的字换掉（取词进来时用），并把光标放好
    func setSearchText(_ text: String) {
        searchField?.stringValue = text
    }

    func focusSearch() {
        guard let searchField else { return }
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    private func showPane(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        if !built.contains(id) {
            let view = pane.makePaneView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            contentHost.view.addSubview(view)
            // **贴安全区，不是贴 bounds**。窗口开了 fullSizeContentView，
            // 内容视图是一直伸到标题栏底下的；贴 bounds 的话每一页最上面那一行
            // （词典设置的列头、查词页的语种胶囊）都会被工具栏压住。
            let safe = contentHost.view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: safe.topAnchor),
                view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
            built.insert(id)
            paneViews[id] = view
        }
        for (key, view) in paneViews { view.isHidden = key != id }
        pane.paneWillAppear(config: config)
        window?.subtitle = pane.paneTitle
    }

    private var paneViews: [PaneID: NSView] = [:]

    // MARK: - 搭窗口

    private func build() {
        guard window == nil else { return }

        let sidebarVC = SidebarViewController()
        sidebarVC.onSelect = { [weak self] id in self?.select(id) }
        sidebar = sidebarVC

        contentHost.view = NSView()

        let splitVC = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 168
        sidebarItem.maximumThickness = 260
        // 窗口窄下去时让侧边栏自己收起来，别把主显示区挤没
        sidebarItem.canCollapse = true
        splitVC.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentHost)
        contentItem.minimumThickness = 420
        splitVC.addSplitViewItem(contentItem)
        split = splitVC

        let win = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                         .fullSizeContentView],
                             backing: .buffered, defer: false)
        win.title = t("about.title")
        win.contentViewController = splitVC
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.minSize = NSSize(width: 760, height: 480)
        win.setFrameAutosaveName("QuickDictMain")
        win.center()

        let toolbar = NSToolbar(identifier: "QuickDictMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar
        // .unified 让工具栏和标题栏合成一条，侧边栏的毛玻璃一直顶到窗口顶部 ——
        // 这是「看起来像原生 App」和「看起来像套壳」的分界线
        win.toolbarStyle = .unified

        win.onCommandDigit = { [weak self] index in
            guard let self, self.current == .lookup,
                  let lookup = self.panes[.lookup] as? LookupPane else { return }
            lookup.selectSite(index)
        }
        win.onFocusQuery = { [weak self] in
            self?.select(.lookup)
            self?.focusSearch()
        }
        win.onZoom = { [weak self] delta in
            guard let self, let lookup = self.panes[.lookup] as? LookupPane else { return }
            lookup.zoom(by: delta)
        }

        window = win
        sidebarVC.select(current)
    }

    // MARK: - 工具栏

    private enum ItemID {
        static let search = NSToolbarItem.Identifier("search")
        static let screenshot = NSToolbarItem.Identifier("screenshot")
        static let selection = NSToolbarItem.Identifier("selection")
        static let clipboard = NSToolbarItem.Identifier("clipboard")
        static let speak = NSToolbarItem.Identifier("speak")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator,
         ItemID.screenshot, ItemID.selection, ItemID.clipboard, ItemID.speak,
         .flexibleSpace, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == ItemID.search {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = t("home.placeholder")
            item.searchField.target = self
            item.searchField.action = #selector(searchSubmitted)
            // 回车才查。边打边查的话每敲一个字母就开一次词典页，网页词典受不了
            item.searchField.sendsWholeSearchString = true
            item.searchField.sendsSearchStringImmediately = false
            item.resignsFirstResponderWithCancel = true
            // 不给上限的话它会一直撑到窗口边上，看着像个地址栏而不是搜索框
            item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            searchField = item.searchField
            return item
        }

        let map: [NSToolbarItem.Identifier: (String, String, String)] = [
            ItemID.screenshot: ("camera.viewfinder", t("menu.lookup"), "screenshot"),
            ItemID.selection: ("text.cursor", t("menu.selection"), "selection"),
            ItemID.clipboard: ("doc.on.clipboard", t("menu.clipboard"), "clipboard"),
            ItemID.speak: ("speaker.wave.2", t("help.act.speak"), "speak"),
        ]
        guard let (symbol, label, action) = map[id] else { return nil }

        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = #selector(captureItemClicked(_:))
        item.tag = ["screenshot": 0, "selection": 1, "clipboard": 2, "speak": 3][action] ?? 0
        return item
    }

    @objc private func captureItemClicked(_ sender: NSToolbarItem) {
        let actions = ["screenshot", "selection", "clipboard", "speak"]
        guard actions.indices.contains(sender.tag) else { return }
        onCapture?(actions[sender.tag])
    }

    @objc private func searchSubmitted() {
        let text = (searchField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onLookup?(text, nil)
    }

    // MARK: - 窗口事件

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false        // 菜单栏 App：关窗口不等于退出
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.level = .normal
    }
}

// MARK: - 键盘

/// 主窗口自己吃几个快捷键。
///
/// ⌘1…⌘9 换词典、⌘L 回到查词框、⌘+/-/0 调字号 —— 这些原来挂在查词浮窗上，
/// 浮窗没了就挪到这里，行为一模一样。放在窗口层而不是菜单，是因为它们只在
/// 查词那一页有意义，做成全局菜单项会在别的页里变成死键。
final class MainWindow: NSWindow {
    var onCommandDigit: ((Int) -> Void)?
    var onFocusQuery: (() -> Void)?
    /// 传 nil 表示回到 100%
    var onZoom: ((Double?) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "0" { onZoom?(nil); return true }
            if let n = Int(chars), (1...9).contains(n) { onCommandDigit?(n - 1); return true }
            if chars == "l" { onFocusQuery?(); return true }
            // 「＋」在多数键盘上要按 shift，所以 = 和 + 都认
            if chars == "=" || chars == "+" { onZoom?(0.1); return true }
            if chars == "-" { onZoom?(-0.1); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 侧边栏

/// 左侧导航。用 `NSTableView` 的 group row 分组，配 `.sidebar` 材质 ——
/// 和「访达」「邮件」「系统设置」是同一套外观，不是自己画的仿品。
final class SidebarViewController: NSViewController {
    var onSelect: ((PaneID) -> Void)?

    /// 展开成「分组标题 + 条目」的平表。分组标题是 String，条目是 PaneID。
    private let rows: [Any] = {
        var out: [Any] = []
        for id in PaneID.allCases {
            if let section = id.section { out.append(section) }
            out.append(id)
        }
        return out
    }()

    private var table: NSTableView!

    override func loadView() {
        let table = NSTableView()
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 26
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main")))
        table.dataSource = self
        table.delegate = self
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // 让系统自己算内边距：标题栏和工具栏有多高由外观风格决定，
        // 写死一个数字的话第一组的标题会被压在标题栏底下看不见
        scroll.automaticallyAdjustsContentInsets = true

        // 版本号钉在侧栏右下角。**不能放进 tableView** —— 那样它会跟着列表滚动，
        // 而且会占掉一个可选中的行。所以外面套一层容器，滚动区和它并排。
        // 版本号 + 构建号两行。**只有版本号是分不清的** —— 3.3_beta 一天不会变，
        // 而一天可能装七八回。构建号是 build.sh 每次盖的 MMDD.HHMM。
        let stamp = appBuild.isEmpty ? "v\(appVersion)" : "v\(appVersion)\n构建 \(appBuild)"
        let version = NSTextField(labelWithString: stamp)
        version.font = .systemFont(ofSize: 10, weight: .regular)
        version.textColor = .tertiaryLabelColor
        version.alignment = .right
        version.maximumNumberOfLines = 2
        version.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(version)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: version.topAnchor, constant: -2),
            version.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            // 贴安全区，不是贴 bounds —— 侧栏底部在某些窗口样式下有系统留白
            version.bottomAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        view = container
    }

    func select(_ id: PaneID) {
        guard let index = rows.firstIndex(where: { ($0 as? PaneID) == id }) else { return }
        table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row] is String
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row] is PaneID
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        if let section = rows[row] as? String {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: section)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        guard let id = rows[row] as? PaneID else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: id.symbol,
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: id.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.imageView = icon
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard rows.indices.contains(row), let id = rows[row] as? PaneID else { return }
        onSelect?(id)
    }
}
