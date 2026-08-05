import AppKit
import WebKit

final class LookupPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCommandDigit: ((Int) -> Void)?
    var onFocusQuery: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if let n = Int(chars), (1...9).contains(n) {
                onCommandDigit?(n - 1)
                return true
            }
            if chars == "l" { onFocusQuery?(); return true }
            if chars == "w" { onCancel?(); return true }
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

    private var sites: [DictSite] = []
    private var currentIndex = 0
    private var config: AppConfig = .fallback
    private var didPosition = false
    private var isPinned = false

    // MARK: - 对外入口

    func present(text: String, route: RouteResult, config: AppConfig, index: Int) {
        self.config = config
        self.sites = config.dictionaries
        buildWindowIfNeeded()

        queryField.stringValue = text
        langLabel.stringValue = route.ambiguous ? "\(route.displayName)?" : route.displayName
        langLabel.toolTip = route.ambiguous
            ? t("window.langUncertain", String(format: "%.0f%%", route.confidence * 100))
            : t("window.langCertain", route.displayName)
        langLabel.textColor = route.ambiguous ? .systemOrange : .secondaryLabelColor

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

    func hide() { panel?.orderOut(nil) }

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
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
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

        langLabel = NSTextField(labelWithString: "")
        langLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        langLabel.textColor = .secondaryLabelColor
        langLabel.alignment = .center
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

        let toolbar = NSStackView(views: [langLabel, queryField, siteSelector, browserButton, pinButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let webConfig = WKWebViewConfiguration()
        webConfig.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.navigationDelegate = self
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
        webView.load(URLRequest(url: url))
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
