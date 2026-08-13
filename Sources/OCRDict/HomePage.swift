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
                   staysLoggedIn: !config.clearDataOnQuit)
        }
    }

    static func html(config: AppConfig, status: Status) -> String {
        """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style></head><body>
        <header>
          <h1>\(esc(t("about.title")))<span class="ver">\(esc(appVersion))</span></h1>
          <p class="tagline">\(t("home.tagline"))</p>
        </header>

        <div class="search">
          <input id="q" type="search" autofocus placeholder="\(esc(t("home.placeholder")))">
          <button id="go">\(t("home.lookup"))</button>
        </div>

        \(actionSection(config))
        \(dictionarySection(config))
        \(statusSection(status))
        \(footerSection())
        <script>\(script)</script></body></html>
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
            ("\u{1F5BC}", t("menu.lookup"), key(source: .screenshot, action: .lookup)),
            ("\u{1F58B}", t("menu.selection"), key(source: .selection, action: .lookup)),
            ("\u{1F4CB}", t("menu.clipboard"), key(source: .screenshot, action: .clipboard)),
            ("\u{1F50A}", t("help.act.speak"), key(source: .selection, action: .speak)),
        ]
        let cards = entries.enumerated().map { index, entry in
            """
            <button class="card" data-do="\(["screenshot", "selection", "clipboard", "speak"][index])">
            <span class="ico">\(entry.0)</span><span class="what">\(esc(entry.1))</span>
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
            let kind = site.isDatabase ? "\u{1F4C0}" : (site.isNotes ? "\u{1F4C4}"
                                                       : (site.external == true ? "\u{2197}" : "\u{1F310}"))
            return """
            <button class="row" data-dict="\(esc(site.id))">
            <span class="ico">\(kind)</span><b>\(esc(site.name))</b>
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

    private static func footerSection() -> String {
        let items = [("onboarding", t("menu.onboarding")), ("dictionaries", t("menu.dictionaries")),
                     ("hotkeys", t("menu.hotkeys")), ("help", t("menu.help")),
                     ("config", t("menu.editConfig"))]
        let buttons = items.map {
            "<button class=\"link\" data-do=\"\($0.0)\">\(esc($0.1))</button>"
        }.joined()
        return "<h2>\(t("home.h.settings"))</h2><div class=\"links\">\(buttons)</div>"
    }

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 输入框回车、点词典、点动作，全部发回 App 处理
    private static let script = """
    const box = document.getElementById('q');
    function send(payload) { window.webkit.messageHandlers.quickdict.postMessage(payload); }
    function lookup(dict) {
      const text = box.value.trim();
      if (!text) { box.focus(); return; }
      send({action: 'lookup', text: text, dict: dict || ''});
    }
    document.getElementById('go').onclick = () => lookup();
    box.addEventListener('keydown', e => { if (e.key === 'Enter') lookup(); });
    document.addEventListener('click', e => {
      const dict = e.target.closest('[data-dict]');
      if (dict) { lookup(dict.dataset.dict); return; }
      const act = e.target.closest('[data-do]');
      if (act) send({action: 'run', what: act.dataset.do});
    });
    window.addEventListener('focus', () => box.focus());
    """

    private static let css = """
    :root { color-scheme: light dark; --fg:#1d1d1f; --dim:#86868b; --line:#e5e5e7;
            --bg:#fff; --card:#f5f5f7; --accent:#0b6bcb; --good:#1a8f3c; --bad:#c25e00; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#f5f5f7; --dim:#98989d; --line:#38383a; --bg:#1c1c1e;
              --card:#2c2c2e; --accent:#6cb2ff; --good:#4cd571; --bad:#ff9f45; }
    }
    * { box-sizing:border-box; }
    body { margin:0; padding:26px 30px 40px; background:var(--bg); color:var(--fg);
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
    .card .ico { font-size:17px; }
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
    .links { display:flex; flex-wrap:wrap; gap:8px; }
    .link { padding:7px 14px; font-size:13px; }
    """
}
