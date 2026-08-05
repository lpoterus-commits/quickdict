import Foundation

/// 使用说明的 HTML，**从当前配置实时生成**。
/// 这样改了快捷键或加了词典，说明会跟着变，不会出现文档和实际对不上的情况。
/// 文案全部走 `t()`，加一种语言只要补一份 Localizable.strings。
enum HelpDocument {
    static func html(config: AppConfig) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(css)</style></head><body>
        <h1>\(esc(t("about.title"))) <span class="ver">\(esc(appVersion))</span></h1>
        <p class="lead">\(t("help.lead"))</p>
        \(hotkeySection(config))
        \(windowSection(config))
        \(dictionarySection(config))
        \(permissionSection())
        \(configSection(config))
        \(troubleSection())
        <p class="foot">\(t("help.foot"))</p>
        </body></html>
        """
    }

    // MARK: - 各段

    private static func hotkeySection(_ config: AppConfig) -> String {
        func rows(_ list: [HotKeyBinding]) -> String {
            list.map { binding in
                let (what, detail) = describe(binding, config: config)
                return "<tr><td><kbd>\(esc(binding.displayString))</kbd></td>"
                    + "<td><b>\(esc(what))</b></td><td>\(esc(detail))</td></tr>"
            }.joined()
        }
        let head = "<tr><th>\(t("help.colKey"))</th><th>\(t("help.colWhat"))</th>"
            + "<th>\(t("help.colNote"))</th></tr>"
        // 「自己输入」是可选绑定，没配就不显示这一节，免得表格空着
        let manual = config.hotkeys.filter { $0.captureSource == .manual }

        return """
        <h2>\(t("help.h.shortcuts"))</h2>
        <h3>\(t("help.h.screenshot"))</h3>
        <table>\(head)\(rows(config.hotkeys.filter { $0.captureSource == .screenshot }))</table>
        <h3>\(t("help.h.selection"))</h3>
        <table>\(head)\(rows(config.hotkeys.filter { $0.captureSource == .selection }))</table>
        \(manual.isEmpty ? "" : """
        <h3>\(t("help.h.manual"))</h3>
        <table>\(head)\(rows(manual))</table>
        """)
        <p class="tip">\(t("help.tip.sources"))</p>
        """
    }

    private static func windowSection(_ config: AppConfig) -> String {
        let switches = config.dictionaries.enumerated().prefix(9).map { index, site in
            "<kbd>⌘\(index + 1)</kbd> \(esc(site.name))"
        }.joined(separator: "　")

        return """
        <h2>\(t("help.h.window"))</h2>
        <table>
        <tr><td><kbd>⌘1</kbd>…<kbd>⌘9</kbd></td><td>\(t("help.win.switch"))</td><td>\(switches)</td></tr>
        <tr><td><kbd>⌘L</kbd></td><td>\(t("help.win.edit"))</td><td>\(t("help.win.editNote"))</td></tr>
        <tr><td><kbd>esc</kbd> / <kbd>⌘W</kbd></td><td>\(t("help.win.close"))</td><td>\(t("help.win.closeNote"))</td></tr>
        <tr><td>📌</td><td>\(t("help.win.pin"))</td><td>\(t("help.win.pinNote"))</td></tr>
        <tr><td>🔊</td><td>\(t("help.win.speak"))</td><td>\(t("help.win.speakNote"))</td></tr>
        <tr><td>🧭</td><td>\(t("help.win.browser"))</td><td>\(t("help.win.browserNote"))</td></tr>
        <tr><td><kbd>⌘+</kbd> <kbd>⌘-</kbd> <kbd>⌘0</kbd></td><td>\(t("help.win.zoom"))</td><td>\(t("help.win.zoomNote"))</td></tr>
        </table>
        <p class="tip">\(t("help.tip.level"))</p>
        """
    }

    private static func dictionarySection(_ config: AppConfig) -> String {
        let rows = config.dictionaries.enumerated().map { index, site -> String in
            let auto = site.languages.isEmpty
                ? "<span class=dim>\(t("help.dict.manual"))</span>"
                : (site.languages.contains("*") ? t("help.dict.fallback")
                   : site.languages.map { LanguageNames.display($0) }.joined(separator: " / "))
            let note = site.external == true ? t("help.dict.external") : ""
            return "<tr><td><kbd>⌘\(index + 1)</kbd></td><td><b>\(esc(site.name))</b></td>"
                + "<td>\(auto)</td><td>\(note)</td></tr>"
        }.joined()

        return """
        <h2>\(t("help.h.dictionaries"))</h2>
        <table><tr><th>#</th><th>\(t("help.colName"))</th>
        <th>\(t("help.colWhen"))</th><th></th></tr>\(rows)</table>
        <p class="tip">\(t("help.tip.detection"))</p>
        """
    }

    private static func permissionSection() -> String {
        """
        <h2>\(t("help.h.permissions"))</h2>
        <p>\(t("help.perm.intro"))</p>
        <table>
        <tr><th>\(t("help.colPermission"))</th><th>\(t("help.colUsedFor"))</th><th>\(t("help.colIfDenied"))</th></tr>
        <tr><td>\(t("help.perm.screen"))</td><td>\(t("help.perm.screenUse"))</td><td>\(t("help.perm.screenDenied"))</td></tr>
        <tr><td>\(t("help.perm.ax"))</td><td>\(t("help.perm.axUse"))</td><td>\(t("help.perm.axDenied"))</td></tr>
        </table>
        <p class="tip">\(t("help.tip.diagnostics"))</p>
        """
    }

    private static func configSection(_ config: AppConfig) -> String {
        """
        <h2>\(t("help.h.settings"))</h2>
        <p>\(t("help.cfg.hotkeys"))</p>
        <p>\(t("help.cfg.file"))</p>
        <p class="path">\(esc(ConfigStore.fileURL.path))</p>
        <table>
        <tr><th>\(t("help.colWant"))</th><th>\(t("help.colWhere"))</th></tr>
        <tr><td>\(t("help.cfg.targetLang"))</td><td>\(t("help.cfg.targetLangHow"))</td></tr>
        <tr><td>\(t("help.cfg.addDict"))</td><td>\(t("help.cfg.addDictHow"))</td></tr>
        <tr><td>\(t("help.cfg.aiPrompt"))</td><td>\(t("help.cfg.aiPromptHow"))</td></tr>
        <tr><td>\(t("help.cfg.needLogin"))</td><td>\(t("help.cfg.needLoginHow"))</td></tr>
        <tr><td>\(t("help.cfg.alwaysTop"))</td><td><code>alwaysOnTop: true</code></td></tr>
        <tr><td>\(t("help.cfg.qrConfirm"))</td><td><code>qrConfirmBeforeOpen: true</code></td></tr>
        </table>
        <p class="tip">\(t("help.tip.privacy", t(config.clearDataOnQuit ? "diag.on" : "diag.off")))</p>
        """
    }

    private static func troubleSection() -> String {
        """
        <h2>\(t("help.h.trouble"))</h2>
        <table>
        <tr><th>\(t("help.colSymptom"))</th><th>\(t("help.colCause"))</th></tr>
        <tr><td>\(t("help.tr.noResponse"))</td><td>\(t("help.tr.noResponseWhy"))</td></tr>
        <tr><td>\(t("help.tr.nothingAfterCapture"))</td><td>\(t("help.tr.nothingAfterCaptureWhy"))</td></tr>
        <tr><td>\(t("help.tr.noSelection"))</td><td>\(t("help.tr.noSelectionWhy"))</td></tr>
        <tr><td>\(t("help.tr.permsLost"))</td><td>\(t("help.tr.permsLostWhy"))</td></tr>
        <tr><td>\(t("help.tr.badJoin"))</td><td>\(t("help.tr.badJoinWhy"))</td></tr>
        <tr><td>\(t("help.tr.langMissing"))</td><td>\(t("help.tr.langMissingWhy"))</td></tr>
        </table>
        """
    }

    // MARK: - 工具

    private static func describe(_ binding: HotKeyBinding, config: AppConfig) -> (String, String) {
        if binding.captureSource == .manual {
            return (t("help.act.manual"), t("help.act.manualNote"))
        }
        switch binding.captureAction {
        case .clipboard: return (t("help.act.clipboard"), t("help.act.clipboardNote"))
        case .qrcode: return (t("help.act.qr"), t("help.act.qrNote"))
        case .speak: return (t("help.act.speak"), t("help.act.speakNote"))
        case .speakFaster: return (t("keys.actionFaster"), t("help.act.rateNote"))
        case .speakSlower: return (t("keys.actionSlower"), t("help.act.rateNote"))
        case .lookup:
            guard let id = binding.targetDictionary else {
                return (t("help.act.lookupAuto"), t("help.act.lookupAutoNote"))
            }
            let name = config.dictionaries.first { $0.id == id }?.name ?? id
            return (t("action.lookupFixed", t("keys.actionLookup"), name), t("help.act.lookupFixedNote"))
        }
    }

    /// 词典名和路径来自用户配置，得转义，否则一个尖括号就能把页面搞坏
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root { color-scheme: light dark; --fg:#1d1d1f; --dim:#86868b; --line:#e0e0e2;
            --bg:#fff; --card:#f5f5f7; --warn:#c25e00; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#f5f5f7; --dim:#98989d; --line:#38383a; --bg:#1c1c1e;
              --card:#2c2c2e; --warn:#ff9f45; }
    }
    * { box-sizing: border-box; }
    body { margin:0; padding:28px 32px 48px; background:var(--bg); color:var(--fg);
           font:15px/1.7 -apple-system, "PingFang SC", sans-serif; }
    h1 { font-size:26px; margin:0 0 6px; letter-spacing:-.3px; }
    h2 { font-size:18px; margin:34px 0 10px; padding-top:16px; border-top:1px solid var(--line); }
    h3 { font-size:14px; font-weight:600; color:var(--dim); margin:18px 0 8px; }
    .lead { color:var(--dim); margin:0 0 4px; }
    table { width:100%; border-collapse:collapse; margin:8px 0 4px; }
    th { text-align:left; font-size:12px; font-weight:600; color:var(--dim);
         padding:6px 10px; border-bottom:1px solid var(--line); white-space:nowrap; }
    td { padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
    tr:last-child td { border-bottom:none; }
    td:first-child { white-space:nowrap; width:1%; }
    kbd { display:inline-block; background:var(--card); border:1px solid var(--line);
          border-radius:5px; padding:1px 7px; font:13px ui-monospace, Menlo, monospace;
          white-space:nowrap; }
    code { background:var(--card); border-radius:4px; padding:1px 5px;
           font:12.5px ui-monospace, Menlo, monospace; }
    .tip { background:var(--card); border-radius:8px; padding:10px 14px;
           margin:12px 0 0; font-size:13.5px; color:var(--dim); }
    .tip b { color:var(--fg); }
    .path { font:12.5px ui-monospace, Menlo, monospace; color:var(--dim);
            background:var(--card); border-radius:6px; padding:8px 12px; word-break:break-all; }
    .dim { color:var(--dim); }
    .warn { color:var(--warn); }
    .ver { font-size:14px; font-weight:400; color:var(--dim); vertical-align:middle; }
    .foot { margin-top:36px; padding-top:14px; border-top:1px solid var(--line);
            font-size:12.5px; color:var(--dim); }
    """
}
