import AppKit
import ApplicationServices

/// 读取当前 App 里选中的文字。
///
/// 两条路：
///   1. Accessibility API 直接读 kAXSelectedText —— 不碰剪贴板、无固定延迟，首选。
///   2. 模拟 ⌘C 再读剪贴板 —— 兼容性更好（Chrome 不开 AXManualAccessibility 时、部分 Electron App），
///      但会短暂占用剪贴板，所以读完立刻原样还原，不留窗口期。
/// 两条路都需要「辅助功能」权限。
enum SelectionReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹系统授权提示（只在未授权时有效）
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func read() -> String {
        if let text = viaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return viaClipboard() ?? ""
    }

    // MARK: - 路线 1：Accessibility

    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused
        else { return nil }

        // CFTypeRef 到 AXUIElement 的转换，失败就走回落
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
    }

    // MARK: - 路线 2：模拟 ⌘C

    private static func viaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        // 等用户松开触发热键的修饰键，否则合成的 ⌘C 会和还按着的 ⌥ 叠成 ⌘⌥C
        Thread.sleep(forTimeInterval: 0.06)
        postCommandC()

        // 轮询 changeCount 而不是固定 sleep：快的 App 几十毫秒就好了
        var copied: String?
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        restore(saved, to: pasteboard)
        return copied
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let cKey: CGKeyCode = 8 // kVK_ANSI_C
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 整条剪贴板都存下来，不只是纯文本 —— 否则会把用户剪贴板里的图片/富文本弄丢
    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type] = data }
            }
            return payload
        }
    }

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]],
                                to pasteboard: NSPasteboard) {
        guard !snapshot.isEmpty else { return }
        pasteboard.clearContents()
        let items = snapshot.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
