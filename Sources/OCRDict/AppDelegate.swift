import AppKit
import CoreGraphics
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private let resultWindow = ResultWindowController()
    private let helpWindow = HelpWindowController()
    private let hotKeyEditor = HotKeyEditorController()
    private var config = AppConfig.fallback
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigStore.load()
        setupMainMenu()
        setupStatusItem()
        applyHotKeys()

        // 调试用：--test <词> 跳过截图直接开结果窗口，方便改词典配置时试链接
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test"), i + 1 < args.count {
            handle(text: args[i + 1], config: config)
        }
        if args.contains("--help-window") { showHelp() }
        if args.contains("--hotkey-window") { showHotKeyEditor() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
        if config.clearDataOnQuit {
            WebData.clearBlocking()
        }
    }

    // MARK: - 主流程

    /// 菜单里的「截图取词」
    @objc func triggerLookup() {
        captureScreen(.make(key: "", source: .screenshot, dictionary: "auto"))
    }

    /// 菜单里的「截图转文字」
    @objc func triggerClipboardCapture() {
        captureScreen(.make(key: "", source: .screenshot, action: .clipboard))
    }

    /// 菜单里的「扫二维码」
    @objc func triggerQRCapture() {
        captureScreen(.make(key: "", source: .screenshot, action: .qrcode))
    }

    /// 菜单里的「划词取词」
    @objc func triggerSelectionLookup() {
        lookupBySelection(forced: nil)
    }

    private func dispatch(_ binding: HotKeyBinding) {
        switch binding.captureSource {
        case .screenshot: captureScreen(binding)
        case .selection: lookupBySelection(forced: binding.targetDictionary)
        }
    }

    /// 截图一次，按 action 分流
    private func captureScreen(_ binding: HotKeyBinding) {
        guard !isBusy else { return }

        // screencapture 是子进程，但屏幕录制权限记在本 App 头上，先自检避免截出黑图
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            HUD.shared.show(t("hud.needScreenRecording"), duration: 4)
            return
        }

        isBusy = true
        let cfg = config
        let action = binding.captureAction
        let forced = binding.targetDictionary

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch ScreenCapture.interactive() {
            case .failure(let failure):
                DispatchQueue.main.async {
                    self?.isBusy = false
                    switch failure {
                    case .cancelled: break // 用户主动取消，静默
                    case .launchFailed(let msg): HUD.shared.show(t("hud.captureFailed", msg), duration: 3)
                    case .decodeFailed: HUD.shared.show(t("hud.decodeFailed"))
                    }
                }

            case .success(let image):
                switch action {
                case .qrcode:
                    let hits = QRCode.detect(in: image)
                    DispatchQueue.main.async {
                        self?.isBusy = false
                        self?.handleBarcodes(hits, config: cfg)
                    }

                case .clipboard:
                    let lines = OCR.recognizeLines(image: image, languages: cfg.ocrLanguages,
                                                   autoDetect: cfg.autoDetectLanguage)
                    let joined = LineJoiner.joined(lines)
                    DispatchQueue.main.async {
                        self?.isBusy = false
                        self?.copyToClipboard(joined)
                    }

                case .lookup:
                    let raw = OCR.recognize(image: image, languages: cfg.ocrLanguages,
                                            autoDetect: cfg.autoDetectLanguage)
                    let text = TextClean.normalize(raw, collapseToSpace: cfg.collapseWhitespaceToSpace)
                    DispatchQueue.main.async {
                        self?.isBusy = false
                        self?.handle(text: text, config: cfg, forced: forced)
                    }
                }
            }
        }
    }

    private func copyToClipboard(_ result: LineJoiner.Result) {
        let text = result.text
        guard !text.isEmpty else {
            HUD.shared.show(t("hud.noText"))
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
        guard !result.ambiguous.isEmpty else {
            HUD.shared.show(t("hud.copied", text.count, preview), duration: 2.5)
            return
        }
        // 合并对不对取决于上下文，本地判不了，直接把位置报出来让人自己扫一眼
        let shown = result.ambiguous.prefix(3).joined(separator: "、")
        let more = result.ambiguous.count > 3 ? t("hud.andMore", result.ambiguous.count) : ""
        HUD.shared.show(t("hud.copiedAmbiguous", text.count, preview, shown + more), duration: 5)
    }

    private func handleBarcodes(_ hits: [QRCode.Hit], config cfg: AppConfig) {
        guard let hit = hits.first else {
            HUD.shared.show(t("hud.noBarcode"))
            return
        }

        guard let url = hit.url else {
            // 不是 http 链接（可能是纯文本、WIFI:、mailto: 等），放剪贴板让用户自己处置
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hit.payload, forType: .string)
            let preview = hit.payload.count > 60 ? String(hit.payload.prefix(60)) + "…" : hit.payload
            HUD.shared.show(t("hud.barcodeNotURL", hit.symbology, preview), duration: 3.5)
            return
        }

        if cfg.qrConfirmBeforeOpen {
            let alert = NSAlert()
            alert.messageText = t("qr.confirmTitle")
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: t("qr.open"))
            alert.addButton(withTitle: t("qr.copyOnly"))
            alert.addButton(withTitle: t("qr.cancel"))
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(url)
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                HUD.shared.show(t("hud.linkCopied"))
            default: break
            }
            return
        }

        NSWorkspace.shared.open(url)
        // 二维码是不可读的，把实际打开的域名亮出来，扫到奇怪的东西能立刻发现
        HUD.shared.show(t("hud.barcodeOpened", url.host ?? url.absoluteString), duration: 2.5)
    }

    private func lookupBySelection(forced: String?) {
        guard !isBusy else { return }

        // 两条读取路线（AX 直读 / 模拟 ⌘C）都要辅助功能权限
        guard SelectionReader.isTrusted else {
            SelectionReader.requestTrust()
            HUD.shared.show(t("hud.needAccessibility"), duration: 4)
            return
        }

        isBusy = true
        let cfg = config
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = SelectionReader.read()
            let text = TextClean.normalize(raw, collapseToSpace: cfg.collapseWhitespaceToSpace)
            DispatchQueue.main.async {
                self?.isBusy = false
                guard !text.isEmpty else {
                    HUD.shared.show(t("hud.noSelection"))
                    return
                }
                self?.handle(text: text, config: cfg, forced: forced)
            }
        }
    }

    /// forced 非 nil 时跳过语种路由，直接用指定 id 的词典
    private func handle(text: String, config cfg: AppConfig, forced: String? = nil) {
        guard !text.isEmpty else {
            HUD.shared.show(t("hud.noText"))
            return
        }
        let route = LanguageRouter.route(text, config: cfg)
        let index = forced.flatMap { id in cfg.dictionaries.firstIndex { $0.id == id } }
            ?? DictRouter.index(for: route.language, in: cfg.dictionaries)

        guard cfg.dictionaries.indices.contains(index) else {
            HUD.shared.show(t("hud.noDictionary"))
            return
        }

        // 全局设了跳浏览器，或这一项标了 external，都不开窗
        if cfg.openInBrowser || cfg.dictionaries[index].external == true {
            guard let url = DictRouter.url(site: cfg.dictionaries[index], query: text) else {
                HUD.shared.show(t("hud.badURL"))
                return
            }
            NSWorkspace.shared.open(url)
            return
        }
        resultWindow.present(text: text, route: route, config: cfg, index: index)
    }

    // MARK: - 热键

    private func applyHotKeys() {
        let failed = hotKey.register(config.hotkeys) { [weak self] binding in
            self?.dispatch(binding)
        }
        if !failed.isEmpty {
            let names = failed.map(\.displayString).joined(separator: "  ")
            HUD.shared.show(t("hud.hotkeysFailed", names), duration: 4)
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: t("window.title")) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "A文"
            }
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let shot = NSMenuItem(title: "\(t("menu.lookup"))　\(hotkeyLabel(for: .screenshot))",
                              action: #selector(triggerLookup), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        let selection = NSMenuItem(title: "\(t("menu.selection"))　\(hotkeyLabel(for: .selection))",
                                   action: #selector(triggerSelectionLookup), keyEquivalent: "")
        selection.target = self
        menu.addItem(selection)

        let toClipboard = NSMenuItem(title: "\(t("menu.clipboard"))　\(hotkeyLabel(action: .clipboard))",
                                     action: #selector(triggerClipboardCapture), keyEquivalent: "")
        toClipboard.target = self
        toClipboard.toolTip = t("menu.clipboard.tip")
        menu.addItem(toClipboard)

        let qr = NSMenuItem(title: "\(t("menu.qrcode"))　\(hotkeyLabel(action: .qrcode))",
                            action: #selector(triggerQRCapture), keyEquivalent: "")
        qr.target = self
        menu.addItem(qr)
        menu.addItem(.separator())

        let editKeys = NSMenuItem(title: t("menu.hotkeys"), action: #selector(showHotKeyEditor), keyEquivalent: "")
        editKeys.target = self
        menu.addItem(editKeys)

        let help = NSMenuItem(title: t("menu.help"), action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        help.toolTip = t("menu.help.tip")
        menu.addItem(help)
        menu.addItem(.separator())

        let openConfig = NSMenuItem(title: t("menu.editConfig"), action: #selector(openConfigFile), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let reload = NSMenuItem(title: t("menu.reloadConfig"), action: #selector(reloadConfig), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(.separator())

        let clear = NSMenuItem(title: t("menu.clearData", WebData.formatted(WebData.diskUsage())),
                               action: #selector(clearWebData), keyEquivalent: "")
        clear.target = self
        clear.toolTip = t("menu.clearData.tip")
        menu.addItem(clear)

        let clearOnQuit = NSMenuItem(title: t("menu.clearOnQuit"), action: #selector(toggleClearOnQuit), keyEquivalent: "")
        clearOnQuit.target = self
        clearOnQuit.state = config.clearDataOnQuit ? .on : .off
        menu.addItem(clearOnQuit)
        menu.addItem(.separator())

        let login = NSMenuItem(title: t("menu.launchAtLogin"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let diagnose = NSMenuItem(title: t("menu.diagnostics"), action: #selector(showDiagnostics), keyEquivalent: "")
        diagnose.target = self
        menu.addItem(diagnose)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// 菜单里显示该输入源第一个「查词 + 自动路由」的快捷键
    private func hotkeyLabel(for source: CaptureSource) -> String {
        let match = config.hotkeys.first {
            $0.captureSource == source && $0.captureAction == .lookup && $0.targetDictionary == nil
        } ?? config.hotkeys.first { $0.captureSource == source }
        return match?.displayString ?? t("action.notSet")
    }

    private func hotkeyLabel(action: CaptureAction) -> String {
        config.hotkeys.first { $0.captureAction == action }?.displayString ?? t("action.notSet")
    }

    /// 「截图 → 有道」这样的一行说明，自检和关于面板共用
    private func describe(_ binding: HotKeyBinding) -> String {
        let source = binding.captureSource == .selection ? t("action.selection") : t("action.screenshot")
        switch binding.captureAction {
        case .clipboard: return t("action.clipboard", source)
        case .qrcode: return t("action.qrcode", source)
        case .lookup:
            let target = binding.targetDictionary
                .flatMap { id in config.dictionaries.first { $0.id == id }?.name }
                ?? ""
            return target.isEmpty ? t("action.lookupAuto", source) : t("action.lookupFixed", source, target)
        }
    }

    @objc private func showHelp() {
        helpWindow.show(config: config)
    }

    @objc private func showHotKeyEditor() {
        // 录制期间必须先把全局热键摘掉，否则按 ⌃⌥9 会直接触发截图，根本录不进去
        hotKey.unregister()
        hotKeyEditor.onClose = { [weak self] in self?.applyHotKeys() }

        hotKeyEditor.show(config: config) { [weak self] bindings in
            guard let self else { return }
            self.config.hotkeys = bindings
            ConfigStore.save(self.config)

            // 立刻重注册，把「这个组合被别人占了」当场反馈回编辑器，而不是等用户按下才发现
            let failed = self.hotKey.register(self.config.hotkeys) { [weak self] binding in
                self?.dispatch(binding)
            }
            self.statusItem.menu = self.buildMenu()
            self.hotKeyEditor.report(failed: failed)
            if failed.isEmpty {
                self.hotKeyEditor.close()
                HUD.shared.show(t("hud.hotkeysUpdated"))
            }
        }
    }

    @objc private func openConfigFile() {
        ConfigStore.save(config) // 确保文件一定存在
        NSWorkspace.shared.open(ConfigStore.fileURL)
    }

    @objc private func reloadConfig() {
        config = ConfigStore.load()
        applyHotKeys()
        statusItem.menu = buildMenu()
        HUD.shared.show(t("hud.configReloaded"))
    }

    @objc private func clearWebData() {
        let before = WebData.diskUsage()
        resultWindow.blankOut()
        WebData.clear { [weak self] in
            let freed = max(0, before - WebData.diskUsage())
            HUD.shared.show(t("hud.dataCleared", WebData.formatted(freed)))
            self?.statusItem.menu = self?.buildMenu()
        }
    }

    @objc private func toggleClearOnQuit() {
        config.clearDataOnQuit.toggle()
        ConfigStore.save(config)
        statusItem.menu = buildMenu()
        HUD.shared.show(t(config.clearDataOnQuit ? "hud.clearOnQuitOn" : "hud.clearOnQuitOff"))
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                HUD.shared.show(t("hud.loginItemOff"))
            } else {
                try SMAppService.mainApp.register()
                HUD.shared.show(t("hud.loginItemOn"))
            }
        } catch {
            HUD.shared.show(t("hud.loginItemFailed", error.localizedDescription), duration: 4)
        }
        statusItem.menu = buildMenu()
    }

    @objc private func showDiagnostics() {
        let granted = CGPreflightScreenCaptureAccess()
        let supported = OCR.supportedLanguages()
        let wanted = config.ocrLanguages
        let missing = wanted.filter { !supported.contains($0) }

        let trusted = SelectionReader.isTrusted
        var lines = [
            t("diag.screenRecording", granted ? t("diag.granted") : t("diag.deniedScreen")),
            t("diag.accessibility", trusted ? t("diag.granted") : t("diag.deniedAX")),
            t("diag.autoDetect", t(config.autoDetectLanguage ? "diag.on" : "diag.off")),
            "",
            t("diag.shortcuts"),
        ]
        for binding in config.hotkeys {
            lines.append("　\(binding.displayString)　\(describe(binding))")
        }
        lines.append("")
        lines.append(t("diag.hintLanguages", wanted.joined(separator: ", ")))
        if !missing.isEmpty {
            lines.append(t("diag.unsupported", missing.joined(separator: ", ")))
        }
        lines.append("")
        lines.append(t("diag.supportedAll"))
        lines.append(supported.joined(separator: ", "))
        lines.append("")
        lines.append(t("diag.configPath", ConfigStore.fileURL.path))

        let alert = NSAlert()
        alert.messageText = "\(t("diag.title"))  ·  \(appVersion)"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: t("diag.ok"))
        if !granted { alert.addButton(withTitle: t("diag.openScreenSettings")) }
        if !trusted { alert.addButton(withTitle: t("diag.openAXSettings")) }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let screenCapture = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

        switch response {
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: granted ? accessibility : screenCapture)!)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: accessibility)!)
        default:
            break
        }
    }

    // MARK: - 主菜单
    // LSUIElement 的 App 不显示菜单栏，但 NSApp.mainMenu 仍然负责派发 ⌘C / ⌘V 这些键盘等价物，
    // 不建这个菜单的话结果窗口里连复制都用不了。

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: t("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("menu.hideWindow"), action: Selector(("performClose:")), keyEquivalent: "w")
        appMenu.addItem(withTitle: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: t("menu.edit"))
        editMenu.addItem(withTitle: t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: t("menu.cut"), action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: t("menu.copy"), action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: t("menu.paste"), action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: t("menu.selectAll"), action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // 有了这一项，任何窗口在前时按 ⌘? 都能调出说明
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: t("menu.helpMenu"))
        let helpEntry = NSMenuItem(title: t("menu.help").replacingOccurrences(of: "…", with: ""), action: #selector(showHelp), keyEquivalent: "?")
        helpEntry.keyEquivalentModifierMask = [.command]
        helpEntry.target = self
        helpMenu.addItem(helpEntry)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(t("about.title")) \(appVersion)"
        let bindings = config.hotkeys
            .map { "\($0.displayString)　\(describe($0))" }
            .joined(separator: "\n")

        alert.informativeText = t("about.body", bindings)
        alert.addButton(withTitle: t("diag.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
