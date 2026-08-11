import AppKit
import WebKit

/// 主页窗口 —— 这个 App 的门面。
///
/// 在这之前所有功能都挂在菜单栏那个下拉菜单里：能用，但没有一个地方能一眼看全
/// 「有哪些词典、快捷键是什么、权限给了没有」。主页把这些摊开摆出来，
/// 顺便自己就能查词，不用先去别处选中一个词。
///
/// 内容用 HTML 渲染而不是手搭控件：这些东西**全都跟着配置变**，
/// 用 HTML 重画一次就是重新生成一遍字符串，比逐个更新控件可靠得多。
/// 使用说明窗口早就是这么做的，这里沿用同一套。
final class HomeWindowController: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    private var window: NSWindow?
    private var webView: WKWebView?

    /// 主页上查词：文本 + 指定词典（空串表示按语种自动选）
    var onLookup: ((String, String?) -> Void)?
    /// 主页上点了某个动作：screenshot / selection / clipboard / speak /
    /// onboarding / dictionaries / hotkeys / help / config
    var onRun: ((String) -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    func show(config: AppConfig) {
        build()
        refresh(config: config)
        // 和其他窗口同样的处理：accessory App 抢不到前台，弹出时先抬到 floating，失焦再沉回去
        window?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// 配置变了就重画。权限是在系统设置里给的，App 这边收不到通知，
    /// 所以每次显示都重新查一遍状态。
    func refresh(config: AppConfig) {
        guard let webView else { return }
        webView.loadHTMLString(HomePage.html(config: config, status: .current(config: config)),
                               baseURL: nil)
    }

    private func build() {
        guard window == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "quickdict")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = t("about.title")
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setFrameAutosaveName("QuickDictHome")
        panel.center()
        window = panel
    }

    // MARK: - 页面发回来的消息

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // 这个窗口只加载自己生成的页面，不会导航到外部，所以不必像结果窗口那样验来源
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "lookup":
            guard let text = (body["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            let dictionary = body["dict"] as? String
            onLookup?(text, (dictionary?.isEmpty ?? true) ? nil : dictionary)
        case "run":
            guard let what = body["what"] as? String else { return }
            onRun?(what)
        default:
            return
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.level = .normal
    }
}

extension HomeWindowController: WKNavigationDelegate {
    /// 主页里的链接走系统浏览器，别把这个窗口导航走
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
