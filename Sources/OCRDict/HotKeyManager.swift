import AppKit
import Carbon.HIToolbox

/// 用 Carbon 的 RegisterEventHotKey 注册全局热键。
/// 相比 CGEventTap 的好处：不需要「辅助功能」权限，系统级独占，不会漏键。
final class HotKeyManager {
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var bindings: [UInt32: HotKeyBinding] = [:]
    private var action: ((HotKeyBinding) -> Void)?

    private static let signature: OSType = 0x4F43_4B44 // 'OCKD'

    /// 返回注册失败的绑定（通常是被系统或别的 App 占用了）
    @discardableResult
    func register(_ list: [HotKeyBinding], action: @escaping (HotKeyBinding) -> Void) -> [HotKeyBinding] {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                hotKeyCallback, 1, &eventType,
                                                selfPtr, &eventHandler)
        guard installStatus == noErr else {
            NSLog("[OCRDict] InstallEventHandler 失败: \(installStatus)")
            return list
        }

        var failed: [HotKeyBinding] = []
        for (index, binding) in list.enumerated() {
            guard let keyCode = binding.resolvedKeyCode else {
                failed.append(binding)
                continue
            }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, binding.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                bindings[id] = binding
            } else {
                NSLog("[OCRDict] 注册 \(binding.displayString) 失败: \(status)")
                failed.append(binding)
            }
        }
        return failed
    }

    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        bindings.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func fire(id: UInt32) {
        guard let binding = bindings[id] else { return }
        DispatchQueue.main.async { [weak self] in self?.action?(binding) }
    }

    deinit { unregister() }
}

private func hotKeyCallback(_ handler: EventHandlerCallRef?,
                            _ event: EventRef?,
                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData, let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return noErr }
    Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().fire(id: hotKeyID.id)
    return noErr
}
