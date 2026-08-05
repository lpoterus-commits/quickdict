import AppKit

/// 点一下进入录制状态，按下的第一个「修饰键 + 键」就是新快捷键。esc 取消。
final class KeyRecorderButton: NSButton {
    var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var displayTitle: String = t("keys.setKey") {
        didSet { if !recording { title = displayTitle } }
    }

    private var monitor: Any?
    private var recording = false

    init(title: String) {
        super.init(frame: .zero)
        displayTitle = title
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        self.title = title
        target = self
        action = #selector(toggleRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleRecording() {
        if recording { stop(); return }
        recording = true
        title = t("keys.recording")

        // 本地监听：录制期间吞掉本 App 的所有按键，避免触发菜单等价物
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            guard event.type == .keyDown else { return nil }

            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53, flags.isEmpty { // esc 取消录制
                self.stop()
                return nil
            }
            // 不带修饰键的全局热键会把普通打字也吞掉，不允许
            guard !flags.isEmpty else { NSSound.beep(); return nil }

            self.onCapture?(UInt32(event.keyCode), flags)
            self.stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = displayTitle
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

final class HotKeyEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var rowsStack: NSStackView!
    private var statusLabel: NSTextField!

    private var bindings: [HotKeyBinding] = []
    private var config: AppConfig = .fallback
    private var onSave: (([HotKeyBinding]) -> Void)?
    /// 关窗时回调，用于恢复被临时注销的全局热键
    var onClose: (() -> Void)?

    func show(config: AppConfig, onSave: @escaping ([HotKeyBinding]) -> Void) {
        self.config = config
        self.bindings = config.hotkeys
        self.onSave = onSave
        build()
        rebuildRows()

        window?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// 保存后由外部回报哪些注册失败了（通常是被别的程序占用）
    func report(failed: [HotKeyBinding]) {
        guard !failed.isEmpty else {
            status(t("keys.saved"), warning: false)
            return
        }
        let names = failed.map(\.displayString).joined(separator: "  ")
        status(t("keys.savedWithFailures", names), warning: true)
        rebuildRows(failed: Set(failed.compactMap(\.resolvedKeyCode)))
    }

    // MARK: - 构建

    private func build() {
        guard window == nil else { return }

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedContainer()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
            rowsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -4),
        ])
        scroll.documentView = clip

        let addButton = NSButton(title: t("keys.add"), target: self, action: #selector(addBinding))
        addButton.bezelStyle = .rounded
        let resetButton = NSButton(title: t("keys.reset"), target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let cancelButton = NSButton(title: t("keys.cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: t("keys.save"), target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonBar = NSStackView(views: [addButton, resetButton, spacer, cancelButton, saveButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: t("keys.hint"))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()

        let content = NSView()
        content.addSubview(header)
        content.addSubview(scroll)
        content.addSubview(statusLabel)
        content.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

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

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = t("keys.title")
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
    }

    private func makeHeader() -> NSStackView {
        func label(_ text: String, _ width: CGFloat) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11, weight: .semibold)
            field.textColor = .secondaryLabelColor
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }
        let stack = NSStackView(views: [
            label(t("keys.colShortcut"), 140), label(t("keys.colSource"), 100),
            label(t("keys.colAction"), 130), label(t("keys.colDictionary"), 170),
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func rebuildRows(failed: Set<UInt32> = []) {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for index in bindings.indices {
            rowsStack.addArrangedSubview(makeRow(index: index, failed: failed))
        }
    }

    private func makeRow(index: Int, failed: Set<UInt32>) -> NSView {
        let binding = bindings[index]

        // 新加的条目还没录键，别显示成一个空按钮
        let recorder = KeyRecorderButton(
            title: binding.resolvedKeyCode == nil ? t("keys.setKey") : binding.displayString)
        recorder.widthAnchor.constraint(equalToConstant: 140).isActive = true
        if let code = binding.resolvedKeyCode, failed.contains(code) {
            recorder.contentTintColor = .systemRed
            recorder.toolTip = t("keys.registerFailedTip")
        }
        recorder.onCapture = { [weak self] keyCode, flags in
            guard let self else { return }
            self.bindings[index] = self.bindings[index].replacingKey(keyCode: keyCode, flags: flags)
            self.validateAndRefresh()
        }

        let source = NSPopUpButton()
        source.addItems(withTitles: [t("keys.sourceScreenshot"), t("keys.sourceSelection"),
                                     t("keys.sourceManual")])
        source.selectItem(at: HotKeyEditorController.sources.firstIndex(of: binding.captureSource) ?? 0)
        source.widthAnchor.constraint(equalToConstant: 110).isActive = true
        source.target = self
        source.action = #selector(sourceChanged(_:))
        source.tag = index

        let action = NSPopUpButton()
        action.addItems(withTitles: [t("keys.actionLookup"), t("keys.actionClipboard"),
                                     t("keys.actionQR"), t("keys.actionSpeak"),
                                     t("keys.actionFaster"), t("keys.actionSlower")])
        switch binding.captureAction {
        case .lookup: action.selectItem(at: 0)
        case .clipboard: action.selectItem(at: 1)
        case .qrcode: action.selectItem(at: 2)
        case .speak: action.selectItem(at: 3)
        case .speakFaster: action.selectItem(at: 4)
        case .speakSlower: action.selectItem(at: 5)
        }
        // 自己输入时没有取到的文字，「只放剪贴板」「扫码」无从谈起
        action.isEnabled = binding.captureSource != .manual
        action.widthAnchor.constraint(equalToConstant: 130).isActive = true
        action.target = self
        action.action = #selector(actionChanged(_:))
        action.tag = index

        let dictionary = NSPopUpButton()
        dictionary.addItem(withTitle: t("keys.dictAuto"))
        config.dictionaries.forEach { dictionary.addItem(withTitle: $0.name) }
        if let id = binding.targetDictionary,
           let position = config.dictionaries.firstIndex(where: { $0.id == id }) {
            dictionary.selectItem(at: position + 1)
        } else {
            dictionary.selectItem(at: 0)
        }
        dictionary.isEnabled = binding.captureAction == .lookup
        dictionary.widthAnchor.constraint(equalToConstant: 170).isActive = true
        dictionary.target = self
        dictionary.action = #selector(dictionaryChanged(_:))
        dictionary.tag = index

        let remove = NSButton(title: "✕", target: self, action: #selector(removeBinding(_:)))
        remove.bezelStyle = .rounded
        remove.tag = index
        remove.toolTip = t("keys.delete")

        let row = NSStackView(views: [recorder, source, action, dictionary, remove])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - 编辑动作

    /// 弹出菜单的顺序，和 keys.source* 三个文案一一对应
    static let sources: [CaptureSource] = [.screenshot, .selection, .manual]

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        let picked = Self.sources[sender.indexOfSelectedItem]
        bindings[sender.tag].source = picked.rawValue
        // 自己输入时窗口是空的，没有词可以拿去做「只放剪贴板」或「扫码」
        if picked == .manual { bindings[sender.tag].action = CaptureAction.lookup.rawValue }
        validateAndRefresh()
    }

    @objc private func actionChanged(_ sender: NSPopUpButton) {
        let actions: [CaptureAction] = [.lookup, .clipboard, .qrcode, .speak, .speakFaster, .speakSlower]
        bindings[sender.tag].action = actions[sender.indexOfSelectedItem].rawValue
        validateAndRefresh()
    }

    @objc private func dictionaryChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        bindings[sender.tag].dictionary = index == 0 ? "auto" : config.dictionaries[index - 1].id
        validateAndRefresh()
    }

    @objc private func removeBinding(_ sender: NSButton) {
        guard bindings.indices.contains(sender.tag) else { return }
        bindings.remove(at: sender.tag)
        validateAndRefresh()
    }

    @objc private func addBinding() {
        bindings.append(.make(key: "", source: .screenshot, dictionary: "auto"))
        validateAndRefresh()
        status(t("keys.newRowHint"), warning: true)
    }

    @objc private func resetDefaults() {
        bindings = AppConfig.fallback.hotkeys
        validateAndRefresh()
        status(t("keys.resetHint"), warning: false)
    }

    @objc private func cancel() {
        window?.orderOut(nil)
        onClose?()
    }

    @objc private func save() {
        guard let problem = firstProblem() else {
            onSave?(bindings)
            return
        }
        status(problem, warning: true)
        NSSound.beep()
    }

    // MARK: - 校验

    /// 返回第一个阻止保存的问题，nil 表示可以保存
    private func firstProblem() -> String? {
        var seen: [String: HotKeyBinding] = [:]
        for binding in bindings {
            guard let code = binding.resolvedKeyCode else {
                return t("keys.needKey")
            }
            let signature = "\(code)-\(binding.carbonModifiers)"
            if seen[signature] != nil {
                return t("keys.duplicate", binding.displayString)
            }
            seen[signature] = binding
        }
        return nil
    }

    private func validateAndRefresh() {
        rebuildRows()
        if let problem = firstProblem() {
            status(problem, warning: true)
        } else {
            status(t("keys.pressSave"), warning: false)
        }
    }

    private func status(_ text: String, warning: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        onClose?()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.level = .normal
    }

    func close() { window?.orderOut(nil)
        }
}

extension HotKeyBinding {
    /// 录制到新组合后替换按键部分，保留来源/动作/词典
    func replacingKey(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> HotKeyBinding {
        var copy = self
        let name = KeyCodeNames.name(for: keyCode)
        if name.hasPrefix("#") {
            copy.key = nil
            copy.keyCode = keyCode // 没有可读名字的键就存原始键码
        } else {
            copy.key = name
            copy.keyCode = nil
        }
        copy.control = flags.contains(.control)
        copy.option = flags.contains(.option)
        copy.shift = flags.contains(.shift)
        copy.command = flags.contains(.command)
        return copy
    }
}
