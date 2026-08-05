import AppKit
import WebKit

/// 使用说明窗口。内容是本地生成的 HTML，不联网。
final class HelpWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?

    func show(config: AppConfig) {
        build()
        webView?.loadHTMLString(HelpDocument.html(config: config), baseURL: nil)

        // 和结果窗口同样的处理：accessory App 抢不到前台，弹出时先抬到 floating，失焦再沉回去
        window?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func build() {
        guard window == nil else { return }

        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = self
        webView = view

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = t("menu.help").replacingOccurrences(of: "…", with: "")
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.level = .normal
    }
}

extension HelpWindowController: WKNavigationDelegate {
    /// 说明书里的链接（如果以后加了）走系统浏览器，别在这个窗口里导航走
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
