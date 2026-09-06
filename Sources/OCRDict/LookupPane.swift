import AppKit
import WebKit

/// 查词页：语种胶囊 + 词典切换 + 内嵌网页。
///
/// 3.1 之前这是一个独立的浮窗（`ResultWindowController`）。收进主窗口之后：
///
/// - **输入框上移到工具栏**。一个 App 里摆两个搜索框，用的人分不清该往哪个里打字。
///   现在窗口顶上那个就是「要查的词」，`⌘L` 回到它，取词进来的字也落在它里面。
/// - **⌘1…⌘9 / ⌘± / ⌘0 挂到窗口上**（见 `MainWindow`），因为只有这一页用得上，
///   做成全局菜单项会在别的页里变成按了没反应的死键。
/// - **图钉给了整个窗口**。原来钉的是浮窗，现在钉的是主窗口，语义一样。
///
/// 除此之外，词典路由、本地词库现场渲染、笔记页回传、弹窗改走浏览器 —— 一个字没改。
final class LookupPane: NSObject, ShellPane, WKScriptMessageHandler {

    var paneTitle: String { t("shell.pane.lookup") }

    private var webView: WKWebView!
    private var langLabel: NSTextField!
    private var siteSelector: NSSegmentedControl!
    private var progress: NSProgressIndicator!
    private var contentView: NSView?

    /// 要查的词。真正的输入框在工具栏上，这里只留一份值 ——
    /// 两边靠 `setQuery` 和 `onQueryChanged` 同步。
    private(set) var query = ""
    private var sites: [DictSite] = []
    private var currentIndex = 0
    private var config: AppConfig = .fallback

    /// 词变了（页面上点了近义词之类），把工具栏那个框也改过来
    var onQueryChanged: ((String) -> Void)?
    /// 页面上改了资料清单，交给外面存配置
    var onNotesChanged: ((DictSite) -> Void)?
    /// 缩放比例存回配置，下次打开还是这个大小
    var onZoomChanged: ((Double) -> Void)?
    /// 出弹窗要挂在窗口上，问外壳要
    var hostWindow: (() -> NSWindow?)?

    // MARK: - 对外入口

    /// 取词进来了：换词、换语种胶囊、按路由结果选词典、加载。
    func show(text: String, route: RouteResult, config cfg: AppConfig, index: Int) {
        config = cfg
        sites = cfg.dictionaries
        setQuery(text)

        langLabel.stringValue = route.ambiguous ? "\(route.displayName)?" : route.displayName
        langLabel.toolTip = route.ambiguous
            ? t("window.langUncertain", String(format: "%.0f%%", route.confidence * 100))
            : t("window.langCertain", route.displayName)
        tintLanguage(uncertain: route.ambiguous)

        rebuildSelector()
        load(index: index)
    }

    /// 切到这一页但没有词的情况：留一页说明，别显示一片白。
    ///
    /// **已经查过的话一个字都不动** —— 菜单栏工具不进 ⌘Tab，把窗口叫回来时
    /// 正读着的释义不能没了。
    func prepareBlank(config cfg: AppConfig) {
        let restoring = !query.isEmpty
        config = cfg
        sites = cfg.dictionaries
        rebuildSelector()
        siteSelector.selectedSegment = min(currentIndex, max(sites.count - 1, 0))
        guard !restoring else { return }
        langLabel.stringValue = ""
        langLabel.toolTip = nil
        tintLanguage(uncertain: false)
        webView.loadHTMLString(Self.blankHint(), baseURL: nil)
    }

    func paneWillAppear(config: AppConfig) {
        prepareBlank(config: config)
    }

    /// 工具栏的搜索框回车走这里
    func lookup(text: String, config cfg: AppConfig, index: Int?) {
        config = cfg
        sites = cfg.dictionaries
        setQuery(text)
        rebuildSelector()
        load(index: index ?? currentIndex)
    }

    /// ⌘1…⌘9
    func selectSite(_ index: Int) { load(index: index) }

    /// 清除浏览数据时一并把当前页面卸掉，否则内存里还留着刚查的词
    func blankOut() {
        setQuery("")
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func setQuery(_ text: String) {
        query = text
        onQueryChanged?(text)
    }

    /// 字号缩放。用 pageZoom 而不是 magnification —— 前者让文字重排，
    /// 后者是整页放大，窄窗口里会横向出滚动条。双指缩放走 magnification（系统管）。
    func zoom(by delta: Double?) {
        guard webView != nil else { return }
        // 取整到两位，否则 0.1 累加会攒出 1.3000000000000003 存进配置
        let value = delta.map { (min(max(config.windowZoom + $0, 0.5), 3.0) * 100).rounded() / 100 } ?? 1.0
        config.windowZoom = value
        webView.pageZoom = value
        onZoomChanged?(value)
        HUD.shared.show("\(Int(value * 100))%", duration: 1)
    }

    // MARK: - 搭视图

    func makePaneView() -> NSView {
        if let contentView { return contentView }

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

        siteSelector = NSSegmentedControl()
        siteSelector.segmentStyle = .rounded
        siteSelector.trackingMode = .selectOne
        siteSelector.target = self
        siteSelector.action = #selector(siteChanged)
        siteSelector.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let speakButton = NSButton(image: NSImage(systemSymbolName: "speaker.wave.2",
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

        let bar = NSStackView(views: [langLabel, siteSelector, speakButton, browserButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false

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
        content.addSubview(bar)
        content.addSubview(separator)
        content.addSubview(webView)
        content.addSubview(progress)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
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

        contentView = content
        return content
    }

    /// 空页的引导。跟随系统深浅色，文案跟随界面语言。
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
        </style>
        <b>\(esc(t("window.blank.title")))</b>
        <div>\(esc(t("window.blank.switch")))</div>
        <div>\(esc(t("window.blank.local")))</div>
        """
    }

    /// 语种胶囊上色。空的时候不画底，免得一切过来就有个突兀的色块。
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

    // MARK: - 加载

    private func load(index: Int) {
        guard sites.indices.contains(index) else { return }
        let site = sites[index]
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = DictRouter.url(site: site, query: text) else { return }

        // 查到一个词，就先把它的读音悄悄合成好。
        // 神经语音算一个词要一秒半，而用户从「看到释义」到「想听一下」中间总有好几秒 ——

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
            // 本地 SQLite 词库：每次查询现场出页面（几万词条不可能整个塞进 HTML）
            if site.isDatabase {
                let source = URL(fileURLWithPath: site.localPath ?? url.path)
                if let page = KrDict.page(database: source, query: text, name: site.name) {
                    webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
                }
                return
            }
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

    private var currentURL: URL? {
        guard sites.indices.contains(currentIndex) else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictRouter.url(site: sites[currentIndex], query: text)
    }

    // MARK: - Actions

    @objc private func siteChanged() { load(index: siteSelector.selectedSegment) }

    /// 读出当前查询词。走全局那台朗读引擎 —— 和 ⌃⌥7 是同一个声音、同一套
    /// 清洗和语种判定，也不会出现两边同时张嘴的情况。
    @objc private func speak() {
        if Speech.shared.isSpeaking {
            Speech.shared.stop()
            return
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Speech.shared.speak(text, config: config)
    }

    @objc private func openInBrowser() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 加载进度

extension LookupPane: WKNavigationDelegate {
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progress.stopAnimation(nil)
        progress.isHidden = true
    }
}

// MARK: - 笔记页面的回传

extension LookupPane {
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
        case "search":
            // 词库页面上点了一个词（近义词、反义词、提示里的词）：换成它再查一次
            guard let text = body["text"] as? String, !text.isEmpty else { return }
            setQuery(text)
            load(index: currentIndex)
        case "speak":
            guard let text = body["text"] as? String, !text.isEmpty else { return }
            Speech.shared.speak(text, config: config)
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

extension LookupPane: WKUIDelegate {
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
        guard let window = hostWindow?() else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }
}
