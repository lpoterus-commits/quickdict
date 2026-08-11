import AppKit

/// 首次启动向导。
///
/// 2.0 的问题是：陌生人装上之后，第一次按快捷键只会看到一个「请去系统设置授权」的提示，
/// 而且词典是作者的母语。前 30 秒决定了他会不会留下，而那 30 秒当时是浪费掉的。
///
/// 这个窗口做三件事：确认我的母语（已按系统语言预选）、引导授权（状态实时刷新）、
/// 提示 Gatekeeper 隔离标记。只在配置文件不存在时自动弹出，之后可从菜单调出。
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var languagePopup: NSPopUpButton!
    private var screenRow: PermissionRow!
    private var axRow: PermissionRow!
    private var quarantineBox: NSView!
    private var restartHint: NSTextField!
    private var pollTimer: Timer?

    var onFinish: ((String) -> Void)?

    /// 配置文件不存在 = 从没跑过
    static var isFirstRun: Bool {
        !FileManager.default.fileExists(atPath: ConfigStore.fileURL.path)
    }

    func show(selected code: String) {
        build()
        selectLanguage(code)
        refreshStatus()
        startPolling()

        window?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    // MARK: - 构建

    private func build() {
        guard window == nil else { return }

        let title = NSTextField(labelWithString: t("onboard.title"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: t("onboard.subtitle"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        // ── 我的母语
        // 和菜单栏用同一个键：这两处指的是同一个设置，名字必须一样，
        // 各写各的迟早会走散（之前就是「查到哪种语言」对「我的母语」）
        let langTitle = sectionTitle(t("menu.dictLanguage"))
        let langNote = note(t("onboard.langNote"))
        languagePopup = NSPopUpButton()
        for target in DictionaryPresets.targets {
            languagePopup.addItem(withTitle: target.endonym)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let langRow = NSStackView(views: [languagePopup, NSView()])
        langRow.orientation = .horizontal

        // ── 权限
        let permTitle = sectionTitle(t("onboard.permTitle"))
        let permNote = note(t("onboard.permNote"))
        screenRow = PermissionRow(name: t("help.perm.screen"), detail: t("onboard.permScreenUse")) {
            _ = CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        axRow = PermissionRow(name: t("help.perm.ax"), detail: t("onboard.permAXUse")) {
            SelectionReader.requestTrust()
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }

        restartHint = NSTextField(wrappingLabelWithString: t("onboard.restartHint"))
        restartHint.font = .systemFont(ofSize: 12)
        restartHint.textColor = .systemOrange
        restartHint.isHidden = true

        let restartButton = NSButton(title: t("onboard.restart"), target: self, action: #selector(restartApp))
        restartButton.bezelStyle = .rounded

        // ── Gatekeeper
        quarantineBox = makeQuarantineBox()
        quarantineBox.isHidden = !Gatekeeper.isQuarantined

        // ── 底部
        let startButton = NSButton(title: t("onboard.start"), target: self, action: #selector(finish))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [restartHint, restartButton, NSView(), startButton])
        footer.orientation = .horizontal
        footer.spacing = 10

        let stack = NSStackView(views: [
            title, subtitle,
            separator(), langTitle, langNote, langRow,
            separator(), permTitle, permNote, screenRow, axRow,
            quarantineBox,
            separator(), footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: subtitle)
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 24, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for view: NSTextField in [subtitle, langNote, permNote, restartHint] {
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        }
        for row: NSView in [screenRow, axRow] {
            row.widthAnchor.constraint(equalToConstant: 480).isActive = true
        }

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = t("onboard.windowTitle")
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
    }

    private func makeQuarantineBox() -> NSView {
        let label = NSTextField(wrappingLabelWithString: t("onboard.quarantine"))
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 350).isActive = true

        let fix = NSButton(title: t("onboard.quarantineFix"), target: self, action: #selector(copyQuarantineFix))
        fix.bezelStyle = .rounded

        let row = NSStackView(views: [label, fix])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        row.layer?.cornerRadius = 8
        return row
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        return field
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return box
    }

    // MARK: - 状态

    private func startPolling() {
        pollTimer?.invalidate()
        // 用户是去系统设置里点的勾，App 收不到通知，只能轮询
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = SelectionReader.isTrusted
        screenRow.setGranted(screen)
        axRow.setGranted(ax)
        quarantineBox.isHidden = !Gatekeeper.isQuarantined
        // 权限授予后必须重启进程才生效，这里明确提示而不是让人以为已经能用了
        restartHint.isHidden = !(screen || ax)
    }

    private func selectLanguage(_ code: String) {
        if let index = DictionaryPresets.targets.firstIndex(where: { $0.code == code }) {
            languagePopup.selectItem(at: index)
        }
    }

    private var selectedCode: String {
        let index = languagePopup.indexOfSelectedItem
        return DictionaryPresets.targets.indices.contains(index)
            ? DictionaryPresets.targets[index].code : "en"
    }

    // MARK: - Actions

    @objc private func languageChanged() { onFinish?(selectedCode) }

    @objc private func copyQuarantineFix() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Gatekeeper.fixCommand, forType: .string)
        HUD.shared.show(t("onboard.quarantineCopied"), duration: 3)
    }

    @objc private func restartApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func finish() {
        onFinish?(selectedCode)
        close()
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish()
        return false
    }

    func windowDidResignKey(_ notification: Notification) { window?.level = .normal }
}

/// 一行权限：名字 + 说明 + 状态灯 + 「去授权」按钮
private final class PermissionRow: NSView {
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusText = NSTextField(labelWithString: "")
    private let actionButton: NSButton
    private let onGrant: () -> Void

    init(name: String, detail: String, onGrant: @escaping () -> Void) {
        self.onGrant = onGrant
        actionButton = NSButton(title: t("onboard.grant"), target: nil, action: nil)
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        statusDot.font = .systemFont(ofSize: 11)
        statusText.font = .systemFont(ofSize: 11)
        statusText.textColor = .secondaryLabelColor
        let status = NSStackView(views: [statusDot, statusText])
        status.orientation = .horizontal
        status.spacing = 4

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(grant)

        let row = NSStackView(views: [text, NSView(), status, actionButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func grant() { onGrant() }

    func setGranted(_ granted: Bool) {
        statusDot.textColor = granted ? .systemGreen : .tertiaryLabelColor
        statusText.stringValue = granted ? t("diag.granted") : t("onboard.notGranted")
        actionButton.isHidden = granted
    }
}

/// 从网上下载的 zip 会带隔离标记，双击只会得到「已损坏，无法打开」。
/// 这是 macOS 开源 App 最常见的第一个 issue，所以自己检测并给出确切命令。
enum Gatekeeper {
    /// 读扩展属性直接有系统调用，为这件事起一个 xattr 进程是多余的。
    /// getxattr 返回属性长度，没有该属性时返回 -1。
    static var isQuarantined: Bool {
        Bundle.main.bundlePath.withCString {
            getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        }
    }

    static var fixCommand: String {
        "xattr -dr com.apple.quarantine \"\(Bundle.main.bundlePath)\""
    }
}
