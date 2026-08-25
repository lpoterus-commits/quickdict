import AppKit
import WebKit

/// 主窗口左侧导航能切到的一页。
///
/// 3.1 之前这个 App 是**六个各自独立的窗口**：主页、查词浮窗、词典设置、快捷键、
/// 使用说明、设置向导。每个都自带标题栏、自己决定开在哪、自己管关闭。
/// 功能都在，但没有一个地方能一眼看全，窗口之间也互相盖来盖去。
///
/// 现在它们都变成一页，装进同一个外壳（`MainWindowController`）。
/// 这个协议就是外壳和页之间的全部约定 —— 故意做得很薄：
/// 页自己管自己的视图和状态，外壳只管「什么时候显示谁」。
protocol ShellPane: AnyObject {
    /// 这一页的视图。**第一次切到才问** —— 六页全在启动时建出来是浪费，
    /// 而查词那页还要连带起一个 WebView，更不该白建。
    func makePaneView() -> NSView

    /// 每次切到这一页时叫一次。权限状态、词典列表这些都可能在别处改过，
    /// 所以是「每次都刷」而不是「建的时候刷一次」。
    func paneWillAppear(config: AppConfig)

    /// 左侧导航里显示的名字。也用作窗口副标题。
    var paneTitle: String { get }
}

extension ShellPane {
    func paneWillAppear(config: AppConfig) {}
}

/// 左侧导航的条目。
enum PaneID: String, CaseIterable {
    case home        // 概览：能干什么、状态怎么样
    case lookup      // 查词（原来那个浮窗）
    case dictionaries
    case hotkeys
    case permissions
    case help

    /// 分组标题。nil 表示跟着上一条走，不另起一组。
    var section: String? {
        switch self {
        case .home: return t("shell.section.use")
        case .dictionaries: return t("shell.section.settings")
        case .help: return t("shell.section.about")
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .home: return t("shell.pane.home")
        case .lookup: return t("shell.pane.lookup")
        case .dictionaries: return t("menu.dictionaries")
        case .hotkeys: return t("menu.hotkeys")
        case .permissions: return t("shell.pane.permissions")
        case .help: return t("menu.help")
        }
    }

    /// SF Symbol。挑的都是 macOS 13 就有的，不用运行时判可用性。
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .lookup: return "character.book.closed"
        case .dictionaries: return "books.vertical"
        case .hotkeys: return "keyboard"
        case .permissions: return "lock.shield"
        case .help: return "questionmark.circle"
        }
    }
}

// MARK: - 只放一张网页的页

/// 内容是一整张 HTML 的页（主页、使用说明、权限自检都是这种）。
///
/// 这个 App 一直用 HTML 渲染那些**跟着配置变**的界面：改了快捷键、加了词典、
/// 给了权限，重新生成一遍字符串就完事，比逐个更新控件可靠得多。搬进外壳后这套不变，
/// 只是不再各自占一个窗口。
class WebPane: NSObject, ShellPane, WKScriptMessageHandlerHolder {
    let paneTitle: String
    /// 当前配置下这一页该显示什么。每次切过来都会再问一遍。
    private let render: (AppConfig) -> String
    /// 页面里按钮回传的动作
    var onAction: ((String, [String: Any]) -> Void)?

    private(set) var webView: WKWebView?

    init(title: String, render: @escaping (AppConfig) -> String) {
        self.paneTitle = title
        self.render = render
        super.init()
    }

    func makePaneView() -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(MessageRelay(self), name: "quickdict")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    func paneWillAppear(config: AppConfig) {
        webView?.loadHTMLString(render(config), baseURL: nil)
    }

    func receive(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }
        onAction?(action, body)
    }
}

extension WebPane: WKNavigationDelegate {
    /// 页面里的链接走系统浏览器，别把这一页导航走
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

// MARK: - 回传通道

/// WKWebView 的 message handler 会被 userContentController **强引用**，
/// 直接把页对象注册进去就成了循环引用，页永远不释放。中间隔这一层弱引用打断它。
protocol WKScriptMessageHandlerHolder: AnyObject {
    func receive(_ body: [String: Any])
}

final class MessageRelay: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandlerHolder?

    init(_ target: WKScriptMessageHandlerHolder) {
        self.target = target
        super.init()
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.receive(body)
    }
}
