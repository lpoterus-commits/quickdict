import Foundation

/// 把自己写的 Markdown 笔记变成能查的词典。
///
/// 直接把 `.md` 丢给 WebView 是不行的 —— 实测三处同时垮：编码被当成非 UTF-8 变乱码、
/// Markdown 语法原样露在页面上、`?q=` 完全没人处理，等于把整个文件从头倒出来。
///
/// 更根本的是**搜索本身要靠转换时算出来的东西**。韩语查的是变形后的词：
/// 看到 `가기로 했어요` 要能找到 `V-기로 하다`。标签里的词性标记（`A/V-`）、
/// 可选成分（`(요)`）、音变标记（`(으)ㄹ`）都不会出现在真实文本里，得先剥掉；
/// 词典形 `-하다` 得按谚文音节推出 `했 / 해`。这些都不在 `.md` 里。
///
/// 所以这里做的事：解析条目 → 算搜索键 → 渲染成一个自包含的 HTML（数据、样式、
/// 搜索全在里面，不联网、不依赖任何库）。
enum Notes {

    /// 条目标题支持两种写法，够覆盖常见的整理习惯：
    ///
    ///     ## 001｜A/V-거든(요)        编号｜形式
    ///     ### 1. V-자마자             ### 编号. 形式
    ///
    /// 有 `## 正文` 这一行的话，之前的目录部分整个跳过。
    struct Entry: Encodable {
        var form: String
        var num: String
        var source: String
        var cat: String
        var gloss: String
        var keys: [String]
        var html: String
    }

    // MARK: - 对外

    /// 一份资料在页面里的身份：显示名 + 原始路径（管理条上的「移除」要用路径）
    private struct Source: Encodable {
        var name: String
        var path: String
        var count: Int
    }

    /// 转换失败不抛错，返回一页说明 —— 查词途中弹异常没有意义，
    /// 让用户看见「你的标题格式是不是不对」比看见崩溃有用。
    static func html(from urls: [URL]) -> String {
        var entries: [Entry] = []
        var sources: [Source] = []
        for url in urls {
            let found = parse(url)
            entries += found
            sources.append(Source(name: url.deletingPathExtension().lastPathComponent,
                                  path: url.path, count: found.count))
        }
        guard !entries.isEmpty else { return problemPage(urls) }
        func json<T: Encodable>(_ value: T) -> String {
            (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return page(data: json(entries), sources: json(sources))
    }

    // MARK: - 解析

    static func parse(_ url: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let source = url.deletingPathExtension().lastPathComponent
        var lines = text.components(separatedBy: .newlines)

        // 索引部分是目录不是内容
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## 正文" }) {
            lines = Array(lines[(start + 1)...])
        }

        // 先看这份笔记用哪种风格。
        //
        // 带编号的（`## 001｜…`、`### 1. …`）说明作者在用分册/分章的结构，
        // 这时 `## 第二章 原因` 是章节标题不是条目，必须靠编号区分。
        //
        // 没有编号的，**最深的那一级标题就是词条**，浅的都是分组。
        // 实例：`#` 分册 → `##` 第一组 → `###` -자마자〔一…就…〕，词条在第三级。
        // 规则简单也就可控：想让词条落在 `##`，那就别用 `###` 做小节。
        let numbered = lines.contains { entryHeading($0) != nil }
        let entryDepth = numbered ? 0 : (lines.compactMap(headingDepth).max() ?? 0)

        var entries: [Entry] = []
        var current: Entry?
        var body: [String] = []
        var counter = 0

        func flush() {
            guard var entry = current else { return }
            entry.html = render(body)
            entries.append(entry)
        }

        for line in lines {
            if let (num, form) = heading(line, entryDepth: entryDepth, counter: &counter) {
                flush()
                current = Entry(form: form, num: num, source: source, cat: "", gloss: "",
                                keys: searchKeys(form), html: "")
                body = []
                continue
            }
            guard current != nil else { continue }
            // 分组/章节标题既不是条目也不是内容，丢掉
            if let depth = headingDepth(line), depth <= max(entryDepth, 2) { continue }
            if let (cat, gloss) = metaLine(line) {
                current?.cat = cat
                current?.gloss = gloss
                continue
            }
            body.append(line)
        }
        flush()
        return entries
    }

    /// `## 标题` 的级数；不是标题就返回 nil
    private static func headingDepth(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6,
              line.dropFirst(hashes).first == " ",
              !line.dropFirst(hashes).trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return hashes
    }

    /// 按这份笔记的风格取条目标题
    private static func heading(_ line: String, entryDepth: Int,
                                counter: inout Int) -> (String, String)? {
        guard entryDepth > 0 else { return entryHeading(line) }
        guard headingDepth(line) == entryDepth else { return nil }
        let form = String(line.dropFirst(entryDepth)).trimmingCharacters(in: .whitespaces)
        counter += 1
        return (String(counter), form)
    }

    /// `## 001｜形式` 或 `### 1. 形式`（编号可带连字符，句号后可以没空格）
    private static func entryHeading(_ line: String) -> (String, String)? {
        if line.hasPrefix("## "), let bar = line.firstIndex(of: "｜") {
            let num = line[line.index(line.startIndex, offsetBy: 3)..<bar]
                .trimmingCharacters(in: .whitespaces)
            guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return nil }
            let form = line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            return form.isEmpty ? nil : (num, form)
        }
        guard line.hasPrefix("### ") else { return nil }
        let rest = line.dropFirst(4)
        guard let dot = rest.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let num = String(rest[..<dot])
        guard !num.isEmpty, num.allSatisfy({ $0.isNumber || $0 == "-" }),
              num.contains(where: \.isNumber) else { return nil }
        let form = rest[rest.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return form.isEmpty ? nil : (num, form)
    }

    /// `**分类**：X　｜　**释义**：Y`
    private static func metaLine(_ line: String) -> (String, String)? {
        guard line.contains("**分类**："), let glossMark = line.range(of: "**释义**：") else { return nil }
        guard let catMark = line.range(of: "**分类**：") else { return nil }
        let between = line[catMark.upperBound..<glossMark.lowerBound]
        let cat = between.trimmingCharacters(in: CharacterSet(charactersIn: " 　|｜*"))
        let gloss = line[glossMark.upperBound...].trimmingCharacters(in: .whitespaces)
        return (cat, gloss)
    }

    // MARK: - 搜索键

    /// 从「A/V-거든(요) / A/V-거든」这样的标签里，抽出真正会出现在句子里的片段。
    static func searchKeys(_ rawForm: String) -> [String] {
        var candidates = Set<String>()
        // 【增补】【总览】这类栏目标记不是语法内容
        var form = rawForm
        while let open = form.firstIndex(of: "【"), let close = form[open...].firstIndex(of: "】") {
            form.replaceSubrange(open...close, with: " ")
        }

        var parts = form.components(separatedBy: " / ")
        // 括号里用「/」分隔的备选也要拆出来
        for group in parts {
            for inner in parenthesised(group) where inner.contains("-") {
                parts += inner.components(separatedBy: "/")
            }
        }

        for raw in parts {
            var piece = raw.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            piece = stripPartOfSpeech(piece)
            // 剥掉词性标记后剩下的「/」才是真正的备选形式（-ㄴ/는다、-아/어서）
            for alt in piece.components(separatedBy: "/") { expand(alt, into: &candidates) }
        }
        return candidates.sorted { $0.count > $1.count }
    }

    /// 词性标记有带分隔符的（`A/V-거든`）也有直接贴着的（`N마다`、`N(이)나`）
    private static func stripPartOfSpeech(_ text: String) -> String {
        for marker in ["A/V", "V/A", "A", "V", "N"] where text.hasPrefix(marker) {
            var rest = Substring(text.dropFirst(marker.count))
            let separated = rest.first == "-" || rest.first == " "
            while let f = rest.first, f == "-" || f == " " { rest = rest.dropFirst() }
            // 「N마다」贴着写也算；但「Naver」这种普通词不能被剃头
            guard separated || rest.first.map(isHangulOrParen) == true else { continue }
            return String(rest).trimmingCharacters(in: .whitespaces)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
    }

    private static func isHangulOrParen(_ c: Character) -> Bool {
        c == "(" || c == "（" || (c.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } ?? false)
    }

    private static func parenthesised(_ text: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var buffer = ""
        for c in text {
            if c == "(" || c == "（" {
                depth += 1
                if depth == 1 { buffer = ""; continue }
            }
            if c == ")" || c == "）" {
                depth -= 1
                if depth == 0 { out.append(buffer) }
                continue
            }
            if depth > 0 { buffer.append(c) }
        }
        return out
    }

    /// 展开可选括号，剥掉不会字面出现的成分
    private static func expand(_ raw: String, into out: inout Set<String>) {
        let piece = raw.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        if piece.isEmpty { return }

        // (요) 这类可选成分：带上和去掉各生成一份。
        // 必须**从内往外**剥 —— 「모르다（+ -(으)ㄴ …）」里拿外层左括号去配第一个右括号
        // 就配到内层那个 `)` 上了，整条就剥不干净。
        var variants: Set<String> = [piece]
        for _ in 0..<4 {
            var grown = Set<String>()
            for v in variants {
                guard let close = v.firstIndex(where: { $0 == ")" || $0 == "）" }),
                      let open = v[..<close].lastIndex(where: { $0 == "(" || $0 == "（" })
                else { continue }
                let inside = String(v[v.index(after: open)..<close])
                let head = String(v[..<open]), tail = String(v[v.index(after: close)...])
                grown.insert(head + inside + tail)
                grown.insert(head + tail)
            }
            if grown.subtracting(variants).isEmpty { break }
            variants.formUnion(grown)
        }

        for variant in variants {
            // 开头的孤立字母（ㄹ ㄴ ㅁ…）和 으 在真实文本里是合进前一个音节的
            var value = Substring(variant.trimmingCharacters(in: .whitespaces))
            while let f = value.first, isLoneJamo(f) || f == "으" { value = value.dropFirst() }
            let cleaned = value.trimmingCharacters(in: .whitespaces)
            collect(cleaned, into: &out)
            // 「-(으)ㄹ 거예요」这类，空格后的部分才是能字面匹配的
            if let space = cleaned.firstIndex(of: " ") {
                collect(String(cleaned[cleaned.index(after: space)...]), into: &out)
            }
        }
    }

    private static func isLoneJamo(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3131...0x3163).contains(v)
    }

    /// 只收纯谚文（可含空格）的片段。
    ///
    /// 单音节也收 —— `-겠-`、`A-게` 本身就是一个音节，丢掉它们整条就查不到。
    /// 噪音由排序兜底：匹配得分按键长算，单音节命中排在最后。
    private static func collect(_ raw: String, into out: inout Set<String>) {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -·?!.？！。"))
        guard !value.isEmpty else { return }
        let scalars = value.unicodeScalars
        guard scalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }),
              scalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) || $0 == " " })
        else { return }

        out.insert(value)
        // 标签写词典形（-수밖에 없다），文本里是活用形（없어요、없었다…）。
        // 去掉 -다 留下词干，才接得上后面的各种词尾。
        if value.hasSuffix("다"), value.count >= 3 {
            let stem = String(value.dropLast())
            out.insert(stem)
            out.formUnion(conjugations(stem))
        }
    }

    // MARK: - 词干活用

    /// 中声索引 → 与「어/아」缩合后的中声。缩合后加终声 ㅆ 就是过去式。
    private static let contraction: [Int: Int] = [
        20: 6,      // ㅣ → ㅕ    버리 → 버려/버렸
        13: 14,     // ㅜ → ㅝ    주   → 줘/줬
        8: 9,       // ㅗ → ㅘ    오   → 와/왔
        0: 0,       // ㅏ → ㅏ    가   → 가/갔
        4: 4,       // ㅓ → ㅓ    서   → 서/섰
        1: 1,       // ㅐ → ㅐ    보내 → 보내/보냈
        5: 5,       // ㅔ → ㅔ
    ]
    /// 하다（여变则）、되다、이다 不按规则来，单列
    private static let irregular: [Character: [String]] =
        ["하": ["했", "해"], "되": ["됐", "돼"], "이": ["였", "이었"]]

    /// 给词干补出「过去式」和「아/어形」—— 规则形直接按谚文音节结构算，
    /// 所以 버리다、마시다、지나다 这些都不用登记。
    static func conjugations(_ stem: String) -> Set<String> {
        guard let last = stem.last else { return [] }
        if let forms = irregular[last] {
            return Set(forms.map { String(stem.dropLast()) + $0 })
        }
        guard let scalar = last.unicodeScalars.first,
              (0xAC00...0xD7A3).contains(scalar.value) else { return [] }
        let code = Int(scalar.value) - 0xAC00
        let cho = code / 588, jung = (code / 28) % 21, jong = code % 28
        // 有终声（먹、있）本身就能接词尾，不用补
        guard jong == 0, let merged = contraction[jung] else { return [] }

        let base = String(stem.dropLast())
        func syllable(_ finalConsonant: Int) -> String {
            String(UnicodeScalar(0xAC00 + cho * 588 + merged * 28 + finalConsonant)!)
        }
        return [base + syllable(0), base + syllable(20)]   // 20 = 终声 ㅆ
    }

    // MARK: - Markdown → HTML

    /// 只处理笔记实际会用到的语法：标题、表格、列表、引用、加粗、行内代码。
    private static func render(_ lines: [String]) -> String {
        var out = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 表格：| … | 后面跟一行分隔线
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isDivider(lines[i + 1]) {
                let head = cells(trimmed)
                i += 2
                var body: [[String]] = []
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    body.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                out += "<table><thead><tr>"
                    + head.map { "<th>\(inline($0))</th>" }.joined()
                    + "</tr></thead><tbody>"
                    + body.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined()
                    + "</tbody></table>"
                continue
            }

            if trimmed.hasPrefix("###") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let level = min(hashes + 1, 6)
                let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                out += "<h\(level)>\(inline(title))</h\(level)>"
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var block: [String] = []
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    block.append(lines[i].trimmingCharacters(in: .whitespaces)
                        .dropFirst().trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out += "<blockquote>\(inline(block.joined(separator: " ")))</blockquote>"
                continue
            }

            if isBullet(trimmed) {
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out += "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
                continue
            }

            if let _ = numberedPrefix(trimmed) {
                var items: [String] = []
                while i < lines.count,
                      let n = numberedPrefix(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(n))
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out += "<ol>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
                continue
            }

            if trimmed.allSatisfy({ $0 == "-" }), trimmed.count >= 3 { i += 1; continue }
            if trimmed.hasPrefix("#") { i += 1; continue }

            var paragraph: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("|") || t.hasPrefix(">") || t.hasPrefix("#")
                    || isBullet(t) || numberedPrefix(t) != nil { break }
                paragraph.append(t)
                i += 1
            }
            if paragraph.isEmpty { i += 1 } else {
                out += "<p>\(inline(paragraph.joined(separator: "<br>")))</p>"
            }
        }
        return out
    }

    private static func isDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.dropFirst().allSatisfy { "-: |".contains($0) } && t.contains("-")
    }

    private static func isBullet(_ t: String) -> Bool {
        (t.hasPrefix("- ") || t.hasPrefix("* ")) && t.count > 2
    }

    /// 返回「1. 」这个前缀的长度，不是列表就返回 nil
    private static func numberedPrefix(_ t: String) -> Int? {
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let after = t.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return nil }
        guard after.dropFirst().first == " " else { return nil }
        return digits.count + 2
    }

    private static func cells(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func inline(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        s = wrap(s, marker: "`", tag: "code")
        s = wrap(s, marker: "**", tag: "strong")
        // 单文件里内部锚点跳不了，只留文字
        s = stripAnchorLinks(s)
        return s.replacingOccurrences(of: "&lt;br&gt;", with: "<br>")
    }

    /// 成对标记替换。落单的标记原样留着，不硬凑一对。
    private static func wrap(_ text: String, marker: String, tag: String) -> String {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return text }
        var out = parts[0]
        var index = 1
        while index < parts.count {
            if index + 1 < parts.count || parts.count % 2 == 1 {
                out += "<\(tag)>\(parts[index])</\(tag)>"
                index += 1
                if index < parts.count { out += parts[index]; index += 1 }
            } else {
                out += marker + parts[index]
                index += 1
            }
        }
        return out
    }

    /// `[文字](#g001)` → `文字`
    private static func stripAnchorLinks(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["),
              let close = rest[open...].firstIndex(of: "]"),
              rest.index(after: close) < rest.endIndex,
              rest[rest.index(after: close)] == "(",
              let end = rest[close...].firstIndex(of: ")") {
            let target = rest[rest.index(close, offsetBy: 2)..<end]
            out += rest[..<open]
            out += target.hasPrefix("#") ? String(rest[rest.index(after: open)..<close])
                                         : String(rest[open...end])
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    // MARK: - 页面

    /// 解析不出条目时，**把实际看到的标题列出来** ——
    /// 只说「应该写成什么样」，人还是不知道自己写的哪里不对。
    private static func problemPage(_ urls: [URL]) -> String {
        let names = urls.map { url -> String in
            let found = (try? String(contentsOf: url, encoding: .utf8))?
                .components(separatedBy: .newlines)
                .filter { $0.hasPrefix("#") }
                .prefix(4)
                .map { "<code>\(escapeHTML($0))</code>" }
                .joined(separator: "<br>") ?? ""
            return "<div class=file><b>\(escapeHTML(url.lastPathComponent))</b>"
                + (found.isEmpty ? "<div class=none>\(t("notes.errNoHeadings"))</div>"
                                 : "<div class=saw>\(t("notes.errSaw"))<br>\(found)</div>")
                + "</div>"
        }.joined()
        return #"""
        <!doctype html><meta charset="utf-8">
        <style>:root{color-scheme:light dark}
        body{margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;
        justify-content:center;gap:12px;padding:0 40px;text-align:center;
        font:14px/1.8 -apple-system,"PingFang SC",sans-serif;color:#8a8a8e}
        b{color:inherit;font-size:14px}
        h3{color:#c1554d;font-size:15px;margin:0}
        code{background:rgba(128,128,128,.18);padding:1px 6px;border-radius:4px;
        font:12px ui-monospace,monospace;display:inline-block;margin:1px 0}
        .file{border:1px solid rgba(128,128,128,.3);border-radius:8px;padding:10px 14px;
        margin:6px 0;text-align:left;max-width:560px}
        .saw,.none{font-size:12px;margin-top:5px;opacity:.85}
        .none{color:#c1554d}</style>
        <h3>__TITLE__</h3>
        <div>__FILES__</div>
        <div>__HINT__</div>
        <div><code>## 001｜A/V-거든(요)</code>　<code>### 1. V-자마자</code></div>
        """#
        .replacingOccurrences(of: "__TITLE__", with: t("notes.errTitle"))
        .replacingOccurrences(of: "__FILES__", with: names)
        .replacingOccurrences(of: "__HINT__", with: t("notes.errHint"))
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func page(data: String, sources: String) -> String {
        template
            .replacingOccurrences(of: "__SOURCES__", with: sources)
            .replacingOccurrences(of: "__INTEXT__", with: t("notes.inText"))
            .replacingOccurrences(of: "__MANAGE__", with: t("notes.manage"))
            .replacingOccurrences(of: "__ADD__", with: t("notes.addSource"))
            .replacingOccurrences(of: "__REMOVE__", with: t("notes.removeSource"))
            .replacingOccurrences(of: "__EMPTYSRC__", with: t("notes.noSources"))
            .replacingOccurrences(of: "__PLACEHOLDER__", with: t("notes.searchPlaceholder"))
            .replacingOccurrences(of: "__READY__", with: t("notes.ready"))
            .replacingOccurrences(of: "__EXAMPLE__", with: t("notes.example"))
            .replacingOccurrences(of: "__NOMATCH__", with: t("notes.noMatch"))
            .replacingOccurrences(of: "__NOMATCHTIP__", with: t("notes.noMatchTip"))
            .replacingOccurrences(of: "__COUNT__", with: t("notes.count"))
            .replacingOccurrences(of: "__TOPONLY__", with: t("notes.topOnly"))
            .replacingOccurrences(of: "__MORE__", with: t("notes.more"))
            .replacingOccurrences(of: "__DATA__", with: data)
    }

    private static let template = #"""
    <!doctype html>
    <meta charset="utf-8">
    <style>
    :root { color-scheme: light dark; --bg:#fff; --fg:#1a1a1a; --dim:#6b6b70; --line:#e4e4e7;
            --card:#fbfbfc; --hit:#ffe9a8; --accent:#0a68d8; --accentSoft:#e6f0fd;
            --head:#f4f6f9; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#1c1c1e; --fg:#e8e8ea; --dim:#98989d; --line:#3a3a3c;
              --card:#242427; --hit:#5a4a17; --accent:#5aabff; --accentSoft:#17304d;
              --head:#2b2b30; } }
    * { box-sizing: border-box; }
    body { margin:0; padding:0 16px 40px; background:var(--bg); color:var(--fg);
           font:15px/1.7 -apple-system, "PingFang SC", "Apple SD Gothic Neo", sans-serif; }
    #bar { position:sticky; top:0; background:var(--bg); padding:12px 0 8px; z-index:9;
           border-bottom:1px solid var(--line); }
    #q { width:100%; padding:9px 12px; font-size:15px; border:1px solid var(--line);
         border-radius:8px; background:var(--card); color:var(--fg); outline:none;
         transition:border-color .12s, box-shadow .12s; }
    #q:focus { border-color:var(--accent); box-shadow:0 0 0 3px var(--accentSoft); }
    #count { color:var(--dim); font-size:12px; padding:6px 2px 4px; }

    /* 资料管理条 —— 增删就在这儿，不用去别的窗口 */
    #manage { display:flex; flex-wrap:wrap; gap:6px; align-items:center; padding:2px 0 2px; }
    .chip { display:inline-flex; align-items:center; gap:5px; font-size:11px; color:var(--dim);
            border:1px solid var(--line); border-radius:11px; padding:2px 4px 2px 9px;
            background:var(--card); }
    .chip i { font-style:normal; opacity:.6; font-variant-numeric:tabular-nums; }
    .chip b { font-weight:600; cursor:pointer; }
    .chip b:hover { color:var(--accent); }
    .chip.hit { border-color:var(--accent); color:var(--fg); }
    .chip a { cursor:pointer; opacity:.45; padding:0 4px; border-radius:8px; }
    .chip a:hover { opacity:1; background:rgba(200,60,50,.16); color:#c0392b; }
    .add { cursor:pointer; font-size:11px; color:var(--accent); padding:2px 8px;
           border:1px dashed var(--line); border-radius:11px; }
    .add:hover { border-style:solid; }

    /* 按来源分组，可折叠 */
    .grp { border:1px solid var(--line); border-radius:10px; margin:12px 0;
           background:var(--card); overflow:hidden; }
    /* 吸顶：条目很长，滚动时不吸顶就不知道自己在哪一份资料里 */
    .ghead { position:sticky; top:0; z-index:5; display:flex; align-items:center; gap:8px;
             margin:0; cursor:pointer; padding:9px 14px; font-size:13px; font-weight:600;
             user-select:none; background:var(--head); color:var(--accent);
             box-shadow:0 1px 0 var(--line); }
    .ghead:hover { filter:brightness(0.97); }
    .tri { display:inline-block; width:0; height:0; border:4px solid transparent;
           border-left-color:currentColor; transform:rotate(90deg); opacity:.55;
           transition:transform .12s; }
    .grp.closed .tri { transform:rotate(0deg); }
    .grp.closed .gbody { display:none; }
    .gn { margin-left:auto; font-weight:400; color:var(--dim); font-size:12px;
          font-variant-numeric:tabular-nums; }
    .gbody { padding:2px 14px 12px; }

    .entry { border-top:1px solid var(--line); padding:14px 0 2px; }
    .entry:first-child { border-top:0; padding-top:8px; }
    /* 词条名前面一道竖线：一屏里好几条时，眼睛能顺着它找下一条 */
    .form { font-size:16px; font-weight:600; margin:0 0 4px; padding-left:10px;
            border-left:3px solid var(--accent); line-height:1.35; }
    .meta { color:var(--dim); font-size:12px; margin:0 0 10px 13px; }
    .tag { border-radius:5px; padding:1px 7px; margin-right:6px;
           background:rgba(128,128,128,.13); }
    .tag.intext { background:var(--accentSoft); color:var(--accent); }
    mark { background:var(--hit); color:inherit; border-radius:3px; padding:0 2px; }
    h4,h5,h6 { margin:15px 0 7px; font-size:12px; color:var(--accent);
               letter-spacing:.04em; font-weight:700; text-transform:none;
               display:inline-block; background:var(--accentSoft);
               padding:2px 9px; border-radius:5px; }
    table { border-collapse:collapse; margin:8px 0; font-size:13px; display:block;
            overflow-x:auto; max-width:100%; }
    th,td { border:1px solid var(--line); padding:5px 9px; text-align:left; vertical-align:top; }
    th { background:rgba(128,128,128,.10); font-weight:600; }
    blockquote { margin:8px 0; padding:6px 12px; border-left:3px solid var(--accent);
                 background:rgba(128,128,128,.07); color:var(--dim); }
    ul,ol { margin:6px 0; padding-left:22px; }
    li { margin:3px 0; }
    p { margin:6px 0; }
    code { background:rgba(128,128,128,.15); padding:1px 5px; border-radius:4px; font-size:.9em; }
    .empty { color:var(--dim); text-align:center; padding:40px 0; }
    .more { color:var(--dim); font-size:12px; padding:8px 0 2px; }
    </style>

    <div id="bar">
      <input id="q" placeholder="__PLACEHOLDER__" autofocus>
      <div id="count"></div>
      <div id="manage"></div>
    </div>
    <div id="out"></div>

    <script>
    const DATA = __DATA__;
    const SOURCES = __SOURCES__;
    const out = document.getElementById('out');
    const box = document.getElementById('q');
    const count = document.getElementById('count');
    const manage = document.getElementById('manage');
    const PER_GROUP = 8;

    /* 查询词可能带标点和词尾，先剥干净 */
    function clean(s) {
      return (s || '').replace(/[.,!?;:"'()\[\]{}…·、。，！？；：「」『』〈〉《》]/g, ' ')
                      .replace(/\s+/g, ' ').trim();
    }

    /* 打分：查询词**包含**语法形式 = 强匹配（主用法：把变形词丢进来找语法点）；
       语法形式包含查询词 = 弱匹配（用户在敲形式的一部分）。 */
    /* 去掉空格再比。
       OCR 最常出错的就是韩语的分写：`가기로 했어요` 可能读成 `가기로했어요`，
       `맨손` 可能读成 `맨 손`。实测后者按原样匹配是 0 条 —— 明明有的词查不到。
       忽略空格后，两种偏差都能回到正确写法的结果数。 */
    function squeeze(s) { return s.replace(/\s+/g, ''); }

    /* 每条的派生数据只算一次：正文纯文本、以及各字段去空格后的形式。
       每敲一个字都把几百条重算太慢。 */
    function prep(entry) {
      if (entry._t === undefined) {
        entry._t = entry.html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
        entry._ts = squeeze(entry._t);
        entry._fs = squeeze(entry.form);
        entry._gs = squeeze(entry.gloss + ' ' + entry.cat);
        // 保留原形，命中后要拿它去高亮
        entry._ks = entry.keys.map(k => [k, squeeze(k)]);
      }
      return entry;
    }

    function score(raw, q) {
      const entry = prep(raw);
      let best = 0, hit = '';
      for (const [original, k] of entry._ks) {
        if (!k) continue;
        if (q.includes(k))            { const s = k.length * 3; if (s > best) { best = s; hit = original; } }
        else if (q.length >= 2 && k.includes(q)) { const s = q.length * 2; if (s > best) { best = s; hit = original; } }
      }
      if (entry._fs.includes(q) && q.length >= 2) best = Math.max(best, q.length * 2 + 1);
      if (q.length >= 2 && entry._gs.includes(q)) best = Math.max(best, q.length);
      /* 正文命中给最低分：例句、辨析里出现的词也能搜到，但排在结构性命中之后。
         「밥」在 72 条正文里出现，要是和标题命中同权，真正相关的那条就被淹了。 */
      let inText = false;
      if (entry._ts.includes(q)) { inText = true; best = Math.max(best, 1); }
      return { best, hit, inText };
    }

    function esc(s) { return String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

    /* 增删资料要 App 出手（弹文件选择框、改配置），页面只负责发出请求 */
    function ask(action, path) {
      const h = window.webkit && window.webkit.messageHandlers
             && window.webkit.messageHandlers.quickdict;
      if (h) h.postMessage({ action: action, path: path || '' });
    }

    /* 管理条兼作索引：有查询时显示命中数，点名字直接跳到那一组。
       条目很长，光靠滚动找不到后面的资料。 */
    function renderManage(hits) {
      if (!SOURCES.length) { manage.innerHTML = '<span class="chip">__EMPTYSRC__</span>'; }
      else {
        manage.innerHTML = SOURCES.map((s, i) => {
          const n = hits ? (hits[s.name] || 0) : s.count;
          return '<span class="chip' + (hits && n ? ' hit' : '') + '">'
               + '<b onclick="jump(' + i + ')">' + esc(s.name) + '</b><i>' + n + '</i>'
               + '<a title="__REMOVE__" onclick=\'ask("remove",' + JSON.stringify(s.path) + ')\'>✕</a></span>';
        }).join('');
      }
      manage.innerHTML += '<a class="add" onclick=\'ask("add")\'>＋ __ADD__</a>';
    }

    /* 跳到某一组：先展开，再滚到它的标题下面（标题吸顶，要减掉顶栏高度） */
    function jump(index) {
      const name = SOURCES[index] && SOURCES[index].name;
      const el = Array.from(document.querySelectorAll('.grp'))
                      .find(g => g.dataset.src === name);
      if (!el) return;
      el.classList.remove('closed');
      const bar = document.getElementById('bar').offsetHeight;
      scrollTo({ top: el.offsetTop - bar - 4, behavior: 'smooth' });
    }

    function entryHTML(r) {
      const e = r.e;
      const title = r.hit ? esc(e.form).replace(esc(r.hit), '<mark>' + esc(r.hit) + '</mark>')
                          : esc(e.form);
      return '<div class="entry"><div class="form">' + title + '</div><div class="meta">'
           + (e.cat ? '<span class="tag">' + esc(e.cat) + '</span>' : '')
           + '<span class="tag">#' + esc(e.num) + '</span>'
           + (r.inText && !r.hit ? '<span class="tag intext">__INTEXT__</span>' : '')
           + esc(e.gloss) + '</div>' + e.html + '</div>';
    }

    /* 第一组默认展开，其余折叠 —— 一屏之内看得完，要对照再点开 */
    function groupHTML(g, index) {
      const shown = g.items.slice(0, PER_GROUP);
      const rest = g.items.length - shown.length;
      return '<section class="grp' + (index ? ' closed' : '') + '" data-src="' + esc(g.name) + '">'
           + '<h3 class="ghead" onclick="this.parentNode.classList.toggle(&quot;closed&quot;)">'
           + '<span class="tri"></span>' + esc(g.name)
           + '<span class="gn">' + g.items.length + '</span></h3>'
           + '<div class="gbody">' + shown.map(entryHTML).join('')
           + (rest > 0 ? '<div class="more">… ' + rest + '</div>' : '')
           + '</div></section>';
    }

    function render(q) {
      q = clean(q);
      if (!q) {
        renderManage(null);
        count.textContent = DATA.length + ' __COUNT__';
        out.innerHTML = '<div class="empty">__READY__<br>__EXAMPLE__</div>';
        return;
      }
      const squeezed = squeeze(q);
      const ranked = DATA.map((e, i) => ({ e, i, ...score(e, squeezed) }))
                         .filter(r => r.best > 0)
                         .sort((a, b) => b.best - a.best || a.i - b.i);
      const hits = {};
      ranked.forEach(r => { hits[r.e.source] = (hits[r.e.source] || 0) + 1; });
      renderManage(hits);
      if (!ranked.length) {
        count.textContent = '__NOMATCH__';
        out.innerHTML = '<div class="empty">__NOMATCH__「' + esc(q) + '」<br>'
                      + '<span style="font-size:13px">__NOMATCHTIP__</span></div>';
        return;
      }
      count.textContent = ranked.length + ' __TOPONLY__';
      /* 按资料清单的顺序分组，空的不显示 */
      out.innerHTML = SOURCES
        .map(s => ({ name: s.name, items: ranked.filter(r => r.e.source === s.name) }))
        .filter(g => g.items.length)
        .map(groupHTML).join('');
      highlight(q);
    }

    /* 只动文本节点 —— 正文是 HTML，直接字符串替换会把标签本身也改坏。
       匹配是忽略空格的，所以查询词原样未必出现在文里；找不到就不标，不硬凑。 */
    function highlight(q) {
      if (!q) return;
      for (const entry of document.querySelectorAll('.entry')) {
        const walker = document.createTreeWalker(entry, NodeFilter.SHOW_TEXT);
        const targets = [];
        let node;
        while ((node = walker.nextNode())) {
          if (node.nodeValue.includes(q) && node.parentNode.nodeName !== 'MARK') targets.push(node);
        }
        for (const text of targets) {
          const frag = document.createDocumentFragment();
          text.nodeValue.split(q).forEach((part, i) => {
            if (i) { const m = document.createElement('mark'); m.textContent = q; frag.appendChild(m); }
            if (part) frag.appendChild(document.createTextNode(part));
          });
          text.parentNode.replaceChild(frag, text);
        }
      }
    }

    box.addEventListener('input', () => render(box.value));

    /* 查询词优先看 ?q=，没有再看 #q= */
    function queryFromURL() {
      const search = new URLSearchParams(location.search).get('q');
      if (search) return search;
      const hash = location.hash.replace(/^#/, '');
      if (hash.startsWith('q=')) return decodeURIComponent(hash.slice(2));
      return '';
    }
    const initial = queryFromURL();
    box.value = initial;
    render(initial);
    addEventListener('hashchange', () => { box.value = queryFromURL(); render(box.value); });
    </script>
    """#
}
