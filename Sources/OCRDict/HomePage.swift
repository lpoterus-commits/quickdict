import AppKit
import ApplicationServices

/// 主页内容。**按当前配置实时生成** —— 改了快捷键、加了词典、给了权限，
/// 主页跟着变，不会出现界面和实际对不上的情况。这一点和使用说明是同一套做法。
enum HomePage {

    struct Status {
        var screen: Bool
        var accessibility: Bool
        var database: Bool
        var notes: Int
        /// 词典网站的登录状态能不能留到下次
        var staysLoggedIn: Bool

        static func current(config: AppConfig) -> Status {
            Status(screen: CGPreflightScreenCaptureAccess(),
                   accessibility: AXIsProcessTrusted(),
                   database: DictionaryPresets.bundledDatabase != nil,
                   notes: config.dictionaries.filter(\.isNotes).count,
                   staysLoggedIn: !config.clearLoginsOnQuit)
        }
    }

    /// 主页：这个工具能干什么、词典有哪些。
    ///
    /// **查词框不在这儿了** —— 它上移到了窗口工具栏，任何一页都能用。
    /// 一个 App 里摆两个搜索框，用的人分不清该往哪个里打字。
    /// 设置类的入口也不在这儿了，它们是左侧导航的条目。
    static func html(config: AppConfig, status: Status) -> String {
        """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style></head><body>
        <header>
          <h1>\(esc(t("about.title")))<span class="ver">\(esc(appVersion))</span></h1>
          <p class="tagline">\(t("home.tagline"))</p>
        </header>

        \(actionSection(config))
        \(dictionarySection(config))
        \(warningSection(status))
        <script>\(script)</script></body></html>
        """
    }

    /// 权限那一页。原来它是主页底下的一段，现在单独成页 ——
    /// 权限没给时症状是「按了没反应」，值得在导航里有个能直接点到的地方。
    static func permissionsHTML(config: AppConfig, status: Status) -> String {
        """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style></head><body>
        \(statusSection(status))
        <h2>\(t("home.h.settings"))</h2>
        <div class="links">
          <button class="link" data-do="onboarding">\(esc(t("menu.onboarding")))</button>
          <button class="link" data-do="config">\(esc(t("menu.editConfig")))</button>
        </div>
        <script>\(script)</script></body></html>
        """
    }

    /// 权限缺了才在主页上冒一句，并且直接连到权限那一页。
    /// 都齐了就不占地方 —— 一切正常时最好的界面是没有界面。
    private static func warningSection(_ status: Status) -> String {
        guard !status.screen || !status.accessibility else { return "" }
        return """
        <div class="warn"><b>\(esc(t("home.permMissing")))</b>
        <button class="link" data-do="permissions">\(esc(t("home.permGo")))</button></div>
        """
    }

    // MARK: - 各段

    /// 四个取词入口。快捷键从配置里读 —— 用户改过就显示改过的那个。
    private static func actionSection(_ config: AppConfig) -> String {
        func key(source: CaptureSource, action: CaptureAction) -> String {
            config.hotkeys.first { $0.captureSource == source && $0.captureAction == action }?
                .displayString ?? ""
        }
        let entries: [(String, String, String)] = [
            ("screenshot", t("menu.lookup"), key(source: .screenshot, action: .lookup)),
            ("selection", t("menu.selection"), key(source: .selection, action: .lookup)),
            ("clipboard", t("menu.clipboard"), key(source: .screenshot, action: .clipboard)),
            ("speak", t("help.act.speak"), key(source: .selection, action: .speak)),
        ]
        let cards = entries.map { entry in
            """
            <button class="card" data-do="\(entry.0)">
            \(icon(entry.0))<span class="what">\(esc(entry.1))</span>
            \(entry.2.isEmpty ? "" : "<kbd>\(esc(entry.2))</kbd>")</button>
            """
        }.joined()
        return "<h2>\(t("home.h.capture"))</h2><div class=\"cards\">\(cards)</div>"
    }

    /// 词典一览。点一条 = 用它查上面输入框里的词，等于把 ⌘1…⌘9 摊开摆出来。
    private static func dictionarySection(_ config: AppConfig) -> String {
        let rows = config.dictionaries.enumerated().map { index, site -> String in
            let when: String
            if site.languages.isEmpty { when = t("help.dict.manual") }
            else if site.languages.contains("*") { when = t("help.dict.fallback") }
            else { when = site.languages.map { LanguageNames.display($0) }.joined(separator: " / ") }
            let kind = site.isDatabase ? "database" : (site.isNotes ? "notes"
                                                      : (site.external == true ? "external" : "web"))
            return """
            <button class="row" data-dict="\(esc(site.id))">
            \(icon(kind))<b>\(esc(site.name))</b>
            <span class="when">\(esc(when))</span>
            \(index < 9 ? "<kbd>\u{2318}\(index + 1)</kbd>" : "")</button>
            """
        }.joined()
        return "<h2>\(t("home.h.dictionaries"))</h2><div class=\"list\">\(rows)</div>"
    }

    /// 权限和词库。**给不了的直接说出来，并写清楚少了什么功能** ——
    /// 权限没给时症状是「按了没反应」，不说明的话根本猜不到原因。
    private static func statusSection(_ status: Status) -> String {
        func line(_ ok: Bool, _ label: String, _ detail: String,
                  action: String?, button label2: String = "") -> String {
            let button = (ok || action == nil) ? ""
                : "<button class=\"fix\" data-do=\"\(action!)\">"
                    + (label2.isEmpty ? t("home.fix") : label2) + "</button>"
            return """
            <div class="state \(ok ? "ok" : "bad")"><span class="dot"></span>
            <b>\(esc(label))</b><span class="detail">\(esc(detail))</span>\(button)</div>
            """
        }
        return """
        <h2>\(t("home.h.status"))</h2>
        \(line(status.screen, t("help.perm.screen"),
               status.screen ? t("home.granted") : t("help.perm.screenDenied"), action: "onboarding"))
        \(line(status.accessibility, t("help.perm.ax"),
               status.accessibility ? t("home.granted") : t("help.perm.axDenied"), action: "onboarding"))
        \(line(status.database, t("dict.offlineName"),
               status.database ? t("home.dbReady") : t("home.dbMissing"), action: nil))
        \(line(status.notes > 0, t("home.notes"),
               status.notes > 0 ? t("home.notesCount", status.notes) : t("home.notesNone"),
               action: "dictionaries"))
        \(line(status.staysLoggedIn, t("home.login"),
               status.staysLoggedIn ? t("home.loginKept") : t("home.loginCleared"),
               action: "keepLogin", button: t("home.keepLogin")))
        """
    }

    /// 图标。**不用 emoji** —— 工具栏和侧边栏用的是 SF Symbol，
    /// 主页上摆一排彩色 emoji 会让这一页看着像另一个 App 做的。
    /// 网页里用不了 SF Symbol，所以这里是同样笔画粗细的手写线条图，
    /// 描边走 `currentColor`，深浅色和强调色都跟着系统走。
    private static func icon(_ name: String) -> String {
        let paths: [String: String] = [
            "screenshot":
                "<path d='M3 7V5a2 2 0 012-2h2M17 3h2a2 2 0 012 2v2M21 17v2a2 2 0 01-2 2h-2"
                + "M7 21H5a2 2 0 01-2-2v-2'/><circle cx='12' cy='12' r='3.2'/>",
            "selection":
                "<path d='M12 5v14M9 5h6M9 19h6'/>"
                + "<path d='M5 9V7a2 2 0 012-2h1M19 9V7a2 2 0 00-2-2h-1"
                + "M5 15v2a2 2 0 002 2h1M19 15v2a2 2 0 01-2 2h-1'/>",
            "clipboard":
                "<rect x='8' y='3' width='8' height='4' rx='1.2'/>"
                + "<path d='M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h12a2 2 0 002-2V7a2 2 0 00-2-2h-2'/>"
                + "<path d='M8.5 12h7M8.5 16h4.5'/>",
            "speak":
                "<path d='M4 9.5h3.2L12 5.5v13l-4.8-4H4a1 1 0 01-1-1v-3a1 1 0 011-1z'/>"
                + "<path d='M16 9.2a4 4 0 010 5.6M18.8 6.6a8 8 0 010 10.8'/>",
            "web":
                "<circle cx='12' cy='12' r='8.5'/>"
                + "<path d='M3.5 12h17M12 3.5c4.5 5 4.5 12 0 17M12 3.5c-4.5 5-4.5 12 0 17'/>",
            "database":
                "<ellipse cx='12' cy='6.5' rx='7.5' ry='3'/>"
                + "<path d='M4.5 6.5v11c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3v-11'/>"
                + "<path d='M4.5 12c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3'/>",
            "notes":
                "<path d='M6 3h7l5 5v13a1 1 0 01-1 1H6a1 1 0 01-1-1V4a1 1 0 011-1z'/>"
                + "<path d='M13 3v5h5M8.5 13h7M8.5 17h4.5'/>",
            "external":
                "<path d='M14 4h6v6'/><path d='M20 4l-9 9'/>"
                + "<path d='M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5'/>",
        ]
        guard let d = paths[name] else { return "" }
        return "<svg class=\"ico\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" "
            + "stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\" "
            + "aria-hidden=\"true\">" + d + "</svg>"
    }

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 输入框回车、点词典、点动作，全部发回 App 处理
    private static let script = """
    function send(payload) { window.webkit.messageHandlers.quickdict.postMessage(payload); }
    document.addEventListener('click', e => {
      // 点一本词典 = 切到查词页，用它查工具栏里现在那个词
      const dict = e.target.closest('[data-dict]');
      if (dict) { send({action: 'run', what: 'lookup'}); return; }
      const act = e.target.closest('[data-do]');
      if (act) send({action: 'run', what: act.dataset.do});
    });
    """

    private static let css = """
    :root { color-scheme: light dark; --fg:#1d1d1f; --dim:#86868b; --line:#e5e5e7;
            --bg:#fff; --card:#f5f5f7; --accent:#0b6bcb; --good:#1a8f3c; --bad:#c25e00; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#f5f5f7; --dim:#98989d; --line:#38383a; --bg:#1c1c1e;
              --card:#2c2c2e; --accent:#6cb2ff; --good:#4cd571; --bad:#ff9f45; }
    }
    * { box-sizing:border-box; }
    body { max-width:960px; margin:0; padding:26px 30px 40px; background:var(--bg); color:var(--fg);
           font:14px/1.6 -apple-system,"PingFang SC",sans-serif; }
    header { margin-bottom:18px; }
    h1 { font-size:24px; margin:0; letter-spacing:-.3px; }
    .ver { font-size:12px; font-weight:400; color:var(--dim); margin-left:8px; }
    .tagline { color:var(--dim); font-size:12.5px; margin:4px 0 0; }
    h2 { font-size:12px; font-weight:600; color:var(--dim); margin:24px 0 8px;
         text-transform:uppercase; letter-spacing:.4px; }
    .search { display:flex; gap:8px; }
    #q { flex:1; font-size:16px; padding:10px 14px; border-radius:10px;
         border:1px solid var(--line); background:var(--card); color:var(--fg); }
    #q:focus { outline:2px solid var(--accent); outline-offset:-1px; }
    button { font:inherit; color:var(--fg); cursor:pointer; border:1px solid var(--line);
             background:var(--card); border-radius:10px; }
    button:hover { border-color:var(--accent); }
    #go { padding:0 18px; font-weight:600; }
    .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(118px,1fr)); gap:8px; }
    .card { display:flex; flex-direction:column; align-items:flex-start; gap:3px; padding:11px 12px; }
    .ico { width:18px; height:18px; flex:none; color:var(--accent); }
    .card .ico { width:20px; height:20px; margin-bottom:2px; }
    .card .what { font-weight:600; font-size:13px; }
    .list { display:flex; flex-direction:column; gap:4px; }
    .row { display:flex; align-items:center; gap:10px; padding:9px 14px; text-align:left; }
    .row b { min-width:9em; font-weight:600; }
    .row .when, .card kbd, .row kbd { color:var(--dim); font-size:12px; }
    .row .when { flex:1; }
    kbd { font:12px ui-monospace,Menlo,monospace; border:1px solid var(--line);
          border-radius:5px; padding:0 6px; background:var(--bg); }
    .state { display:flex; align-items:center; gap:9px; padding:7px 2px;
             border-bottom:1px solid var(--line); }
    .state b { min-width:9em; font-weight:500; }
    .dot { width:8px; height:8px; border-radius:50%; flex:none; }
    .ok .dot { background:var(--good); }
    .bad .dot { background:var(--bad); }
    .bad b { color:var(--bad); }
    .detail { color:var(--dim); font-size:12.5px; flex:1; }
    .fix { padding:2px 12px; font-size:12px; }
    .warn { display:flex; align-items:center; gap:10px; margin-top:20px; padding:10px 14px;
            border-radius:10px; background:color-mix(in srgb, var(--bad) 12%, transparent); }
    .warn b { color:var(--bad); font-weight:600; flex:1; }
    .links { display:flex; flex-wrap:wrap; gap:8px; }
    .link { padding:7px 14px; font-size:13px; }
    """
}
