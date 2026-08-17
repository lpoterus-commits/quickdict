import AppKit
import CoreGraphics
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private let resultWindow = ResultWindowController()
    private let helpWindow = HelpWindowController()
    private let hotKeyEditor = HotKeyEditorController()
    private let dictEditor = DictionaryEditorController()
    private let onboarding = OnboardingController()
    private let homeWindow = HomeWindowController()
    private var config = AppConfig.fallback
    private var isBusy = false

    /// 是不是开机自启的那一次。登录项由 launchd 拉起，会带上 XPC_SERVICE_NAME；
    /// 从访达或程序坞点开则没有。
    private var isLoginLaunch: Bool {
        let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return !name.isEmpty && name != "0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 顺序要紧：load() 会把默认配置写出去，写完就不再算首次启动了
        let firstRun = OnboardingController.isFirstRun
        config = ConfigStore.load()
        Reachability.start()
        applyKoreanTables()
        setupMainMenu()
        setupStatusItem()
        applyHotKeys()
        // 结果页面上改了资料清单 —— 存回配置，菜单里的词典列表也跟着更新
        // 主页上的输入框和按钮
        homeWindow.onLookup = { [weak self] text, dictionary in
            guard let self else { return }
            self.handle(text: text, config: self.config, forced: dictionary)
        }
        homeWindow.onRun = { [weak self] what in
            guard let self else { return }
            switch what {
            case "screenshot": self.triggerLookup()
            case "selection": self.triggerSelectionLookup()
            case "clipboard": self.triggerClipboardCapture()
            case "speak": self.speakSelection()
            case "onboarding": self.showOnboarding()
            case "dictionaries": self.showDictionaryEditor()
            case "hotkeys": self.showHotKeyEditor()
            case "help": self.showHelp()
            case "keepLogin":
                self.toggleLogoutOnQuit()
                self.homeWindow.refresh(config: self.config)
            case "config": self.openConfigFile()
            default: break
            }
        }
        resultWindow.onZoomChanged = { [weak self] value in
            guard let self, self.config.windowZoom != value else { return }
            self.config.windowZoom = value
            ConfigStore.save(self.config)
        }
        resultWindow.onNotesChanged = { [weak self] site in
            guard let self, let i = self.config.dictionaries.firstIndex(where: { $0.id == site.id })
            else { return }
            self.config.dictionaries[i] = site
            ConfigStore.save(self.config)
            self.statusItem.menu = self.buildMenu()
        }

        // 调试用：--test <词> 跳过截图直接开结果窗口，方便改词典配置时试链接
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test"), i + 1 < args.count {
            handle(text: args[i + 1], config: config)
        }
        if firstRun {
            showOnboarding()
        } else if !isLoginLaunch && !args.contains("--") {
            // 常规应用启动却不出窗口，看着像没启动成功。
            // 但**开机自启那次不弹** —— 每次登录都糊一个窗口上来才是真烦人。
            showHome()
        }
        // 调试用：--set-lang <code> headless 触发一次母语切换
        if let i = args.firstIndex(of: "--set-lang"), i + 1 < args.count {
            applyDictionaryLanguage(args[i + 1])
            NSApp.terminate(nil)
        }
        // 调试用：--add-source <code> headless 勾选一种要查的外语
        if let i = args.firstIndex(of: "--add-source"), i + 1 < args.count {
            let code = args[i + 1]
            if !config.sourceLanguages.contains(code) { config.sourceLanguages.append(code) }
            rebuildDictionaries()
            NSApp.terminate(nil)
        }
        if args.contains("--home") { showHome() }
        if args.contains("--help-window") { showHelp() }
        if args.contains("--onboarding") { showOnboarding() }
        if args.contains("--hotkey-window") { showHotKeyEditor() }
        if args.contains("--dict-window") { showDictionaryEditor() }
    }

    /// 点程序坞图标（此时可能一个窗口都没开）→ 回到主页。
    /// 常规应用点图标却什么都不发生，会让人以为程序挂了。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showHome() }
        return true
    }

    /// 关掉最后一个窗口不退出 —— 快捷键是全局的，窗口关了它还得随叫随到
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
        // 两个开关各清各的：都开就等于以前那个「全清」
        if config.clearDataOnQuit && config.clearLoginsOnQuit {
            WebData.clearBlocking(.all)
        } else if config.clearDataOnQuit {
            WebData.clearBlocking(.browsing)
        } else if config.clearLoginsOnQuit {
            WebData.clearBlocking(.logins)
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

    /// 菜单里的「主页」
    @objc func showHome() {
        homeWindow.show(config: config)
    }

    /// 菜单里的「打开查词窗口」—— 不取字，自己输入
    @objc func openLookupWindow() {
        resultWindow.openBlank(config: config)
    }

    private func dispatch(_ binding: HotKeyBinding) {
        // 调速和取词来源无关，先拦下
        switch binding.captureAction {
        case .speakFaster: adjustSpeechRate(by: 0.1); return
        case .speakSlower: adjustSpeechRate(by: -0.1); return
        default: break
        }
        switch binding.captureSource {
        case .screenshot: captureScreen(binding)
        case .selection:
            if binding.captureAction == .speak { speakSelection() } else {
                lookupBySelection(forced: binding.targetDictionary)
            }
        case .manual: openLookupWindow()
        case .home: showHome()
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

                case .speak:
                    // 拼行走完整管线：断词还原后的文本才读得顺。
                    // 段落换行 LineJoiner 会保留，正好喂给分节停顿。
                    let lines = OCR.recognizeLines(image: image, languages: cfg.ocrLanguages,
                                                   autoDetect: cfg.autoDetectLanguage)
                    let joined = LineJoiner.joined(lines)
                    DispatchQueue.main.async {
                        self?.isBusy = false
                        guard !joined.text.isEmpty else {
                            HUD.shared.show(t("hud.noText"))
                            return
                        }
                        Speech.shared.speak(joined.text, config: cfg)
                    }

                case .speakFaster, .speakSlower:
                    // dispatch 在截图前就把调速拦下了，到不了这里
                    DispatchQueue.main.async { self?.isBusy = false }

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

    /// 朗读语速加减一档。存进配置（下次启动还是这个速度），
    /// 正在读的话**从下一段起**就是新速度 —— 不打断、不重放。
    private func adjustSpeechRate(by delta: Double) {
        let value = (min(max(config.speechRate + delta, 0.5), 2.0) * 10).rounded() / 10
        config.speechRate = value
        ConfigStore.save(config)
        Speech.shared.setRate(value)
        HUD.shared.show(t("hud.speechRate", Int(value * 100)), duration: 1.2)
    }

    /// 朗读选中的文字。原脚本（左Alt+Q）的行为原样保留：
    /// 有选中读选中，没选中重读上一段，正在读就停。
    private func speakSelection() {
        guard SelectionReader.isTrusted else {
            SelectionReader.requestTrust()
            HUD.shared.show(t("hud.needAccessibility"), duration: 4)
            return
        }
        let cfg = config
        DispatchQueue.global(qos: .userInitiated).async {
            // 不走 TextClean：它会把换行压掉，而换行正是分节停顿的依据
            let raw = SelectionReader.read()
            DispatchQueue.main.async {
                Speech.shared.handleHotkey(selection: raw, config: cfg)
            }
        }
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
            ?? DictRouter.index(for: route.language, in: cfg.dictionaries, online: Reachability.isOnline)

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

        let openWindow = NSMenuItem(title: "\(t("menu.openWindow"))　\(hotkeyLabel(for: .manual))",
                                    action: #selector(openLookupWindow), keyEquivalent: "")
        openWindow.target = self
        openWindow.toolTip = t("menu.openWindow.tip")
        menu.addItem(openWindow)
        let home = NSMenuItem(title: t("menu.home"), action: #selector(showHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)
        menu.addItem(.separator())

        let langItem = NSMenuItem(title: t("menu.dictLanguage"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for target in DictionaryPresets.targets {
            let item = NSMenuItem(title: target.endonym, action: #selector(switchDictionaryLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = target.code
            item.state = (target.code == config.dictionaryLanguage) ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // 要查的外语可以多选 —— 母语只有一个，但生词可能来自好几种语言
        let srcItem = NSMenuItem(title: t("menu.sourceLanguages"), action: nil, keyEquivalent: "")
        let srcMenu = NSMenu()
        for code in DictionaryPresets.selectableSources where code != config.dictionaryLanguage {
            let item = NSMenuItem(title: LanguageNames.display(code),
                                  action: #selector(toggleSourceLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = config.sourceLanguages.contains(code) ? .on : .off
            // 韩语是这个工具的主场，不给取消
            if code == "ko" { item.isEnabled = false }
            srcMenu.addItem(item)
        }
        srcItem.submenu = srcMenu
        menu.addItem(srcItem)

        // 本地词典 App：查词跳到装好的软件而不是网页。只列本机真的有的。
        let localApps = LocalDictionaries.installed
        if !localApps.isEmpty {
            let localItem = NSMenuItem(title: t("menu.localDictionaries"), action: nil, keyEquivalent: "")
            let localMenu = NSMenu()
            for entry in localApps {
                let item = NSMenuItem(title: entry.name, action: #selector(toggleLocalDictionary(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.state = config.dictionaries.contains { $0.id == entry.id } ? .on : .off
                localMenu.addItem(item)
            }
            localItem.submenu = localMenu
            menu.addItem(localItem)
        }

        let setup = NSMenuItem(title: t("menu.onboarding"), action: #selector(showOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let editDicts = NSMenuItem(title: t("menu.dictionaries"), action: #selector(showDictionaryEditor),
                                   keyEquivalent: "")
        editDicts.target = self
        editDicts.toolTip = t("menu.dictionaries.tip")
        menu.addItem(editDicts)

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

        let clearLogins = NSMenuItem(title: t("menu.clearLogins"),
                                     action: #selector(clearWebLogins), keyEquivalent: "")
        clearLogins.target = self
        clearLogins.toolTip = t("menu.clearLogins.tip")
        menu.addItem(clearLogins)

        let clearOnQuit = NSMenuItem(title: t("menu.clearOnQuit"), action: #selector(toggleClearOnQuit), keyEquivalent: "")
        clearOnQuit.target = self
        clearOnQuit.state = config.clearDataOnQuit ? .on : .off
        clearOnQuit.toolTip = t("menu.clearOnQuit.tip")
        menu.addItem(clearOnQuit)

        let logoutOnQuit = NSMenuItem(title: t("menu.logoutOnQuit"),
                                      action: #selector(toggleLogoutOnQuit), keyEquivalent: "")
        logoutOnQuit.target = self
        logoutOnQuit.state = config.clearLoginsOnQuit ? .on : .off
        logoutOnQuit.toolTip = t("menu.logoutOnQuit.tip")
        menu.addItem(logoutOnQuit)
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
        if binding.captureSource == .manual { return t("action.manual") }
        let source = binding.captureSource == .selection ? t("action.selection") : t("action.screenshot")
        switch binding.captureAction {
        case .clipboard: return t("action.clipboard", source)
        case .qrcode: return t("action.qrcode", source)
        case .speak: return t("action.speak", source)
        case .speakFaster: return t("keys.actionFaster")
        case .speakSlower: return t("keys.actionSlower")
        case .lookup:
            let target = binding.targetDictionary
                .flatMap { id in config.dictionaries.first { $0.id == id }?.name }
                ?? ""
            return target.isEmpty ? t("action.lookupAuto", source) : t("action.lookupFixed", source, target)
        }
    }

    private func applyKoreanTables() {
        LineJoiner.configure(extraParticles: config.koreanExtraParticles,
                             extraStandalone: config.koreanExtraStandalone)
    }

    @objc private func showOnboarding() {
        onboarding.onFinish = { [weak self] code in self?.applyDictionaryLanguage(code) }
        onboarding.show(selected: config.dictionaryLanguage)
    }

    @objc private func switchDictionaryLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        applyDictionaryLanguage(code)
        HUD.shared.show(DictionaryPresets.target(for: code).endonym)
    }

    @objc private func toggleSourceLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, code != "ko" else { return }
        if config.sourceLanguages.contains(code) {
            config.sourceLanguages.removeAll { $0 == code }
        } else {
            config.sourceLanguages.append(code)
        }
        rebuildDictionaries()
        HUD.shared.show(t(sender.state == .on ? "hud.sourceRemoved" : "hud.sourceAdded",
                          LanguageNames.display(code)))
    }

    @objc private func toggleLocalDictionary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = LocalDictionaries.known.first(where: { $0.id == id }) else { return }
        if let index = config.dictionaries.firstIndex(where: { $0.id == id }) {
            config.dictionaries.remove(at: index)
            HUD.shared.show(t("hud.localRemoved", entry.name))
        } else {
            config.dictionaries.append(LocalDictionaries.site(for: entry))
            HUD.shared.show(t("hud.localAdded", entry.name), duration: 4)
        }
        ConfigStore.save(config)
        statusItem.menu = buildMenu()
    }

    /// 整套替换词典。手改过词典的人会丢改动，所以只在向导和菜单里显式触发。
    private func applyDictionaryLanguage(_ code: String) {
        guard code != config.dictionaryLanguage || config.dictionaries.isEmpty else { return }
        config.dictionaryLanguage = code
        rebuildDictionaries()
    }

    /// 按当前的「母语 + 要查的外语」重建词典集。
    private func rebuildDictionaries() {
        // 预设只负责它自己那几项。用户手加的词典（id 不属于任何预设）原样保留 ——
        // 换设置不该把别人辛苦配的词典冲掉。
        // 本地词典 App 和手加的词典一样，都不属于预设，换设置时原样保留
        let presetIDs = DictionaryPresets.allPresetDictionaryIDs
        let userAdded = config.dictionaries.filter { !presetIDs.contains($0.id) }
        config.dictionaries = DictionaryPresets.dictionaries(target: config.dictionaryLanguage,
                                                            sources: config.sourceLanguages,
                                                            userDictionaries: userAdded) + userAdded

        // 换语言后词典集变了。指向已不存在词典的快捷键要摘掉，否则按下去没反应还查不出原因。
        let available = Set(config.dictionaries.map(\.id))
        let before = config.hotkeys.count
        config.hotkeys = config.hotkeys.filter { binding in
            guard let target = binding.targetDictionary else { return true }
            return available.contains(target)
        }
        // 新预设里多出来的词典，补上对应的默认键（只在键位没被占用时）
        for candidate in DictionaryPresets.defaultHotkeys(for: config.dictionaries) {
            guard let target = candidate.targetDictionary else { continue }
            let hasTarget = config.hotkeys.contains { $0.targetDictionary == target }
            let keyTaken = config.hotkeys.contains {
                $0.resolvedKeyCode == candidate.resolvedKeyCode
                    && $0.carbonModifiers == candidate.carbonModifiers
            }
            if !hasTarget, !keyTaken { config.hotkeys.append(candidate) }
        }
        if config.hotkeys.count != before { applyHotKeys() }
        ConfigStore.save(config)
        statusItem.menu = buildMenu()
    }

    @objc private func showHelp() {
        helpWindow.show(config: config)
    }

    @objc private func showDictionaryEditor() {
        dictEditor.show(sites: config.dictionaries,
                        config: config,
                        onReset: { [weak self] in
                            guard let self else { return [] }
                            return DictionaryPresets.dictionaries(target: self.config.dictionaryLanguage,
                                                                  sources: self.config.sourceLanguages)
                        },
                        onSave: { [weak self] sites in
                            guard let self else { return }
                            self.config.dictionaries = sites
                            ConfigStore.save(self.config)
                            self.statusItem.menu = self.buildMenu()
                            HUD.shared.show(t("hud.dictionariesSaved", sites.count))
                        })
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
        Reachability.start()
        applyKoreanTables()
        applyHotKeys()
        statusItem.menu = buildMenu()
        HUD.shared.show(t("hud.configReloaded"))
    }

    /// 只清登录 —— 缓存和网站存的搜索记录不动
    @objc private func clearWebLogins() {
        WebData.clear(.logins) { [weak self] in
            HUD.shared.show(t("hud.loginsCleared"))
            self?.statusItem.menu = self?.buildMenu()
        }
    }

    @objc private func toggleLogoutOnQuit() {
        config.clearLoginsOnQuit.toggle()
        ConfigStore.save(config)
        statusItem.menu = buildMenu()
        homeWindow.refresh(config: config)
        HUD.shared.show(t(config.clearLoginsOnQuit ? "hud.logoutOnQuitOn" : "hud.logoutOnQuitOff"))
    }

    /// 清浏览数据 —— **登录留着**。想登出用上面那一项。
    @objc private func clearWebData() {
        let before = WebData.diskUsage()
        resultWindow.blankOut()
        NotesCache.clearAll()
        WebData.clear(.browsing) { [weak self] in
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
        appMenu.addItem(withTitle: t("menu.hideWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: t("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        appMenu.addItem(withTitle: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: t("menu.edit"))
        // undo:/redo: 是响应链上的动作，系统框架里没有任何类声明它们，
        // 所以只能写字符串 —— 其余几项都换成了 #selector，由编译器校对
        editMenu.addItem(withTitle: t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
