import AppKit
import WebKit

final class LookupPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCommandDigit: ((Int) -> Void)?
    var onFocusQuery: (() -> Void)?
    /// 传 nil 表示回到 100%
    var onZoom: ((Double?) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "0" { onZoom?(nil); return true }
            if let n = Int(chars), (1...9).contains(n) {
                onCommandDigit?(n - 1)
                return true
            }
            if chars == "l" { onFocusQuery?(); return true }
            if chars == "w" { onCancel?(); return true }
            // 「＋」在多数键盘上要按 shift，所以 = 和 + 都认
            if chars == "=" || chars == "+" { onZoom?(0.1); return true }
            if chars == "-" { onZoom?(-0.1); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 查词结果窗口：顶部是可编辑的词条 + 词典切换，下面是内嵌网页。
/// 窗口复用，webView 保持热的，第二次查词几乎没有启动成本。
final class ResultWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private var panel: LookupPanel?
    private var webView: WKWebView!
    private var queryField: NSTextField!
    private var langLabel: NSTextField!
    private var siteSelector: NSSegmentedControl!
    private var progress: NSProgressIndicator!
    private var pinButton: NSButton!
    private var speakButton: NSButton!

    private var sites: [DictSite] = []
    private var currentIndex = 0
    private var config: AppConfig = .fallback
    private var didPosition = false
    private var isPinned = false
    /// 页面上改了资料清单，交给外面存配置
    var onNotesChanged: ((DictSite) -> Void)?

    // MARK: - 对外入口

    func present(text: String, route: RouteResult, config: AppConfig, index: Int) {
        self.config = config
        self.sites = config.dictionaries
        buildWindowIfNeeded()

        queryField.stringValue = text
        // openBlank 会把占位文字换成「输入要查的词」，这里是取词来的，换回去
        queryField.placeholderString = t("window.queryPlaceholder")
        langLabel.stringValue = route.ambiguous ? "\(route.displayName)?" : route.displayName
        langLabel.toolTip = route.ambiguous
            ? t("window.langUncertain", String(format: "%.0f%%", route.confidence * 100))
            : t("window.langCertain", route.displayName)
        tintLanguage(uncertain: route.ambiguous)

        rebuildSelector()
        load(index: index)

        positionIfNeeded()
        // 弹出瞬间抬到 floating，否则 accessory App 抢不到前台，窗口会被埋在别的窗口后面。
        // 失去焦点时再沉回 normal（见 windowDidResignKey），这样既能弹出来又不会挡路。
        panel?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        panel?.makeFirstResponder(webView)
    }

    /// 打开查词窗口。
    ///
    /// 这个入口有两个职责，取决于窗口里有没有东西：
    ///
    /// - **空的** → 开一个空窗口，光标落在输入框里，自己敲要查的词
    /// - **已经查过** → 只是把它叫回来，**内容一个字都不动**
    ///
    /// 第二条是要紧的。菜单栏工具不进 ⌘Tab，所以这个快捷键就是「把窗口找回来」的
    /// 唯一办法；要是每次都清空，正读着的释义就没了 —— 那它就没法当这个用。
    func openBlank(config cfg: AppConfig) {
        let restoring = panel != nil && !(queryField?.stringValue.isEmpty ?? true)
        config = cfg
        sites = cfg.dictionaries
        buildWindowIfNeeded()

        rebuildSelector()
        siteSelector.selectedSegment = currentIndex
        if !restoring {
            langLabel.stringValue = ""
            langLabel.toolTip = nil
            tintLanguage(uncertain: false)
            queryField.stringValue = ""
            // 占位文字换掉：这里不是「识别结果」，是等着人输入
            queryField.placeholderString = t("window.queryPlaceholderManual")
            // 还没有词，加载哪个词典都无从谈起。留空会是一片白，所以先放一页说明。
            webView.loadHTMLString(Self.blankHint(), baseURL: nil)
        }

        positionIfNeeded()
        panel?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        // 和 present 的区别就在这一行：焦点给输入框而不是网页。
        // 叫回来的情况也给输入框 —— 想接着改词直接就能打。
        panel?.makeFirstResponder(queryField)
        queryField.selectText(nil)
    }

    /// 空窗口的引导页。跟随系统深浅色，文案跟随界面语言。
    private static func blankHint() -> String {
        """
        <!doctype html><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { margin:0; height:100vh; display:flex; flex-direction:column;
               align-items:center; justify-content:center; gap:10px;
               font:14px/1.7 -apple-system, "PingFang SC", sans-serif;
               color:#8a8a8e; text-align:center; padding:0 32px; }
        b { color:#6a6a6e; font-size:15px; font-weight:600; }
        kbd { border:1px solid currentColor; border-radius:4px; padding:1px 5px;
              font:12px ui-monospace, monospace; opacity:.8; }
        </style>
        <b>\(esc(t("window.blank.title")))</b>
        <div>\(esc(t("window.blank.switch")))</div>
        <div>\(esc(t("window.blank.local")))</div>
        """
    }

    /// 语种胶囊上色。空的时候不画底，免得窗口一开就有个突兀的色块。
    private func tintLanguage(uncertain: Bool) {
        let empty = langLabel.stringValue.isEmpty
        let base: NSColor = uncertain ? .systemOrange : .controlAccentColor
        langLabel.layer?.backgroundColor = empty ? nil : base.withAlphaComponent(0.14).cgColor
        langLabel.textColor = empty ? .secondaryLabelColor : base
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 字号缩放。用 pageZoom 而不是 magnification —— 前者让文字重排，
    /// 后者是整页放大，窄窗口里会横向出滚动条。双指缩放走 magnification（系统管）。
    private func zoom(by delta: Double?) {
        // 取整到两位，否则 0.1 累加会攒出 1.3000000000000003 存进配置
        let value = delta.map { (min(max(config.windowZoom + $0, 0.5), 3.0) * 100).rounded() / 100 } ?? 1.0
        config.windowZoom = value
        webView.pageZoom = value
        onZoomChanged?(value)
        HUD.shared.show("\(Int(value * 100))%", duration: 1)
    }

    /// 缩放比例存回配置，下次打开还是这个大小
    var onZoomChanged: ((Double) -> Void)?

    func hide() {
        panel?.orderOut(nil)
    }

    /// 清除浏览数据时一并把当前页面卸掉，否则内存里还留着刚查的词
    func blankOut() {
        queryField?.stringValue = ""
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }

    // MARK: - 构建

    private func buildWindowIfNeeded() {
        guard panel == nil else { return }

        let window = LookupPanel(
            contentRect: NSRect(x: 0, y: 0, width: config.windowWidth, height: config.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        window.title = t("window.title")
        // 默认走普通窗口层级：切到别的 App 时它就该被正常盖住。
        // 想让它压在最上面时，用工具栏的图钉按钮临时开启。
        window.isFloatingPanel = false
        isPinned = config.alwaysOnTop
        window.level = isPinned ? .floating : .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onCancel = { [weak self] in self?.hide() }
        window.onCommandDigit = { [weak self] i in self?.load(index: i) }
        window.onFocusQuery = { [weak self] in
            guard let self else { return }
            self.panel?.makeFirstResponder(self.queryField)
            self.queryField.selectText(nil)
        }
        window.onZoom = { [weak self] delta in self?.zoom(by: delta) }

        langLabel = NSTextField(labelWithString: "")
        langLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        langLabel.alignment = .center
        // 判出来的语种是这一整次查询的前提，值得比灰字更显眼一点
        langLabel.wantsLayer = true
        langLabel.layer?.cornerRadius = 9
        langLabel.layer?.cornerCurve = .continuous
        langLabel.drawsBackground = false
        langLabel.setContentHuggingPriority(.required, for: .horizontal)
        langLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        queryField = NSTextField(string: "")
        queryField.font = .systemFont(ofSize: 14)
        queryField.placeholderString = t("window.queryPlaceholder")
        queryField.bezelStyle = .roundedBezel
        queryField.delegate = self
        queryField.target = self
        queryField.action = #selector(queryChanged)
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        siteSelector = NSSegmentedControl()
        siteSelector.segmentStyle = .rounded
        siteSelector.trackingMode = .selectOne
        siteSelector.target = self
        siteSelector.action = #selector(siteChanged)
        siteSelector.setContentHuggingPriority(.required, for: .horizontal)

        speakButton = NSButton(image: NSImage(systemSymbolName: "speaker.wave.2",
                                              accessibilityDescription: t("window.speak")) ?? NSImage(),
                               target: self, action: #selector(speak))
        speakButton.bezelStyle = .texturedRounded
        speakButton.toolTip = t("window.speak")
        speakButton.setContentHuggingPriority(.required, for: .horizontal)

        let browserButton = NSButton(image: NSImage(systemSymbolName: "safari",
                                                    accessibilityDescription: t("window.openInBrowser")) ?? NSImage(),
                                     target: self, action: #selector(openInBrowser))
        browserButton.bezelStyle = .texturedRounded
        browserButton.toolTip = t("window.openInBrowser")
        browserButton.setContentHuggingPriority(.required, for: .horizontal)

        pinButton = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: t("window.pin")) ?? NSImage(),
                             target: self, action: #selector(togglePin))
        pinButton.bezelStyle = .texturedRounded
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.setContentHuggingPriority(.required, for: .horizontal)
        updatePinButton()

        let toolbar = NSStackView(views: [langLabel, queryField, siteSelector, speakButton,
                                         browserButton, pinButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let webConfig = WKWebViewConfiguration()
        // 笔记页面上的「＋ 添加 / ✕ 移除」要 App 出手，开一条回传通道。
        // 通道对所有加载的页面都可见，所以收到消息时必须先验来源（见 userContentController）。
        webConfig.userContentController.add(self, name: "quickdict")
        webConfig.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: webConfig)
        // 默认是关的，不开就没有双指缩放
        webView.allowsMagnification = true
        // 双指左右滑 = 前进/后退，词典页里点进详情后能滑回来
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        // 不设 uiDelegate 的话，页面调 window.open() 和 confirm() 会**静默失败** ——
        // Naver 的「加入单词本」就是这么点了没反应的
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(toolbar)
        content.addSubview(separator)
        content.addSubview(webView)
        content.addSubview(progress)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            progress.topAnchor.constraint(equalTo: separator.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window.contentView = content
        panel = window
    }

    private func rebuildSelector() {
        siteSelector.segmentCount = sites.count
        for (i, site) in sites.enumerated() {
            let external = site.external == true
            // ↗ 表示这一项会跳出去开浏览器，而不是在窗口里加载
            siteSelector.setLabel(external ? "\(site.name) ↗" : site.name, forSegment: i)
            siteSelector.setToolTip("\(site.name)  ⌘\(i + 1)\(external ? t("window.external") : "")",
                                    forSegment: i)
        }
    }

    private func updatePinButton() {
        let symbol = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: t("window.pin")) ?? NSImage()
        pinButton.state = isPinned ? .on : .off
        pinButton.toolTip = isPinned ? t("window.pinned") : t("window.pin")
    }

    private func positionIfNeeded() {
        guard !didPosition, let panel else { return }
        didPosition = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = min(config.windowWidth, visible.width - 40)
        let height = min(config.windowHeight, visible.height - 40)
        panel.setFrame(NSRect(x: visible.midX - width / 2,
                              y: visible.midY - height / 2 + visible.height * 0.05,
                              width: width, height: height),
                       display: true)
    }

    // MARK: - 加载

    private func load(index: Int) {
        guard sites.indices.contains(index) else { return }
        let site = sites[index]
        let query = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let url = DictRouter.url(site: site, query: query) else { return }

        if site.external == true {
            NSWorkspace.shared.open(url)
            // WebView 内容没变，把选中状态弹回原来那一项
            siteSelector.selectedSegment = currentIndex
            return
        }

        currentIndex = index
        siteSelector.selectedSegment = index
        webView.pageZoom = config.windowZoom
        if url.isFileURL {
            // 本地资料（自己整理的语法表之类）。指向 .md 的话先转成可查的 HTML。
            let resolved = NotesCache.resolve(url, site: site)
            // file:// 走 load(URLRequest:) 会被 WebKit 拒掉，必须用 loadFileURL 并显式授权可读目录。
            // 授权目录要从**去掉查询串的路径**算，否则 ?q=... 会被当成文件名的一部分。
            let directory = URL(fileURLWithPath: resolved.path).deletingLastPathComponent()
            webView.loadFileURL(resolved, allowingReadAccessTo: directory)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func togglePin() {
        isPinned.toggle()
        panel?.level = isPinned ? .floating : .normal
        updatePinButton()
    }

    private var currentURL: URL? {
        guard sites.indices.contains(currentIndex) else { return nil }
        let query = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictRouter.url(site: sites[currentIndex], query: query)
    }

    // MARK: - Actions

    @objc private func siteChanged() { load(index: siteSelector.selectedSegment) }

    @objc private func queryChanged() { load(index: currentIndex) }

    /// 读出当前查询词。走全局那台朗读引擎 —— 和 ⌘⌥Q 是同一个声音、同一套
    /// 清洗和语种判定，也不会出现两边同时张嘴的情况。
    @objc private func speak() {
        if Speech.shared.isSpeaking {
            Speech.shared.stop()
            return
        }
        let text = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Speech.shared.speak(text, config: config)
    }

    @objc private func openInBrowser() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// 一失去焦点就沉回普通层级，让它不再压着别的窗口。图钉按下时例外。
    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned else { return }
        panel?.level = .normal
    }
}

extension ResultWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.isHidden = false
        progress.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimation(nil)
        progress.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimation(nil)
        progress.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimation(nil)
        progress.isHidden = true
    }
}


// MARK: - 笔记页面的回传

extension ResultWindowController: WKScriptMessageHandler {
    /// 页面上的「＋ 添加 / ✕ 移除」走到这里。
    ///
    /// 这条通道对 WebView 里加载的**所有**页面都可见，包括那些在线词典站点。
    /// 所以先验来源：只接受本机缓存目录里的页面发来的消息，网页发的一律丢掉。
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "quickdict",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let pageURL = webView.url, pageURL.isFileURL,
              pageURL.path.hasPrefix(ConfigStore.directory.path),
              sites.indices.contains(currentIndex)
        else { return }

        var site = sites[currentIndex]
        switch action {
        case "add":
            addNoteSource(to: site)
        case "remove":
            guard let path = body["path"] as? String, !path.isEmpty else { return }
            // 清单为空时 url 里那个路径还在起作用，移除前先把它落实成显式清单
            var list = site.notes ?? currentNoteRoots(site)
            list.removeAll { $0 == path || path.hasPrefix($0 + "/") }
            site.notes = list
            apply(site)
        default:
            return
        }
    }

    /// 清单没显式写过时，实际生效的是 url 里的那个路径
    private func currentNoteRoots(_ site: DictSite) -> [String] {
        guard let url = URL(string: site.url), url.isFileURL else { return [] }
        let root = URL(fileURLWithPath: url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        else { return [] }
        // 指向文件夹时，移除单份资料要能落到具体文件上，所以展开成文件清单
        guard isDirectory.boolValue else { return [root.path] }
        let inside = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return inside.filter { $0.pathExtension.lowercased() == "md" }
                     .sorted { $0.lastPathComponent < $1.lastPathComponent }
                     .map(\.path)
    }

    private func addNoteSource(to original: DictSite) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = t("sheet.filePrompt")
        panel.begin { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            var site = original
            var list = site.notes ?? self.currentNoteRoots(site)
            for url in panel.urls where !list.contains(url.path) { list.append(url.path) }
            site.notes = list
            self.apply(site)
        }
    }

    private func apply(_ site: DictSite) {
        sites[currentIndex] = site
        config.dictionaries = sites
        NotesCache.invalidate(site)
        onNotesChanged?(site)
        rebuildSelector()
        load(index: currentIndex)
    }
}


// MARK: - 弹窗与新窗口

extension ResultWindowController: WKUIDelegate {
    /// `window.open()` 要求宿主再造一个 WebView。这里不造，改成交给默认浏览器。
    ///
    /// 词典站的弹窗基本都是登录、加生词本这类**依赖登录态**的操作，
    /// 而内嵌 WebView 是一个独立的未登录会话 —— 在这里打开只会看到登录页。
    /// 丢给浏览器则直接用上你已有的登录，而且不会把当前查到的词典页顶掉。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        ask(message, cancellable: false) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        ask(message, cancellable: true, done: completionHandler)
    }

    private func ask(_ message: String, cancellable: Bool, done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: t("alert.ok"))
        if cancellable { alert.addButton(withTitle: t("keys.cancel")) }
        guard let panel else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: panel) { done($0 == .alertFirstButtonReturn) }
    }
}
