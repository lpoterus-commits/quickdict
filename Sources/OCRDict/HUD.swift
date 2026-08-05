import AppKit

/// 屏幕中央一闪而过的提示。
/// 没走 UserNotifications，是因为本地签名的 App 通知权限容易失效，而这个永远能显示。
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(_ message: String, duration: TimeInterval = 2.0) {
        dismissTimer?.invalidate()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = 320

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -18),
        ])

        let fitting = effect.fittingSize
        let size = NSSize(width: max(fitting.width, 200), height: max(fitting.height, 60))

        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.contentView = effect
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let screen = currentScreen()
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                      y: frame.midY - size.height / 2))
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 1
        }

        panel = window
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                if self?.panel === window { self?.panel = nil }
            })
        }
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
