import Foundation
import SQLite3

/// 本地 SQLite 词库。
///
/// 数据是国立国语院「한국어기초사전」的官方全量（CC BY-SA），Naver 韩中词典的
/// 韩语基础层用的就是这份。5.6 万词条、7.7 万义项、97.8% 带中文对译，全部离线。
///
/// ## 为什么不能直接查
///
/// 库里存的是**词典形**：`가다`、`먹다`、`모르다`。而 OCR 到的、网页上选中的，
/// 永远是变形后的：`갔어요`、`먹었다`、`몰랐어` —— 实测这三个在库里**一个都查不到**。
/// 官方 `form` 表每个词只给三四个代表形（`가다` → 가/가는/가니/갑니다），远远不够。
///
/// 所以查之前要先还原。这里不列词尾表 —— 词尾列不全，而且新词尾一出现就漏。
/// 改成**扫前缀 + 每个前缀按谚文音节生成词典形候选 + 交给数据库裁决**：
/// 库里没有的候选自然被滤掉，所以候选可以放心多生成。
///
/// 顺序上**真实数据优先**：先查词条表和官方活用形索引，都落空了才动用合成候选。
enum KrDict {

    static func isDatabase(_ url: URL) -> Bool {
        ["sqlite", "sqlite3", "db"].contains(url.pathExtension.lowercased())
    }

    // MARK: - 连接

    /// 句柄留着复用。每次查词重开一遍虽然也就一两毫秒，但查词是高频动作，
    /// 而且这个库只读，没有需要关掉的理由。
    private static var handles: [String: OpaquePointer] = [:]

    private static func open(_ path: String) -> OpaquePointer? {
        if let handle = handles[path] { return handle }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        handles[path] = handle
        return handle
    }

    /// 只给测试用：直接拿到句柄，好把还原逻辑单独拎出来验
    static func debugOpen(_ path: String) -> OpaquePointer? { open(path) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 查询一律走绑定参数 —— 查询词是用户输入，拼进 SQL 里迟早出事
    private static func rows(_ db: OpaquePointer, _ sql: String,
                            _ binds: [Any], columns: Int32) -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in binds.enumerated() {
            let position = Int32(index + 1)
            if let number = value as? Int {
                sqlite3_bind_int64(stmt, position, Int64(number))
            } else {
                sqlite3_bind_text(stmt, position, "\(value)", -1, transient)
            }
        }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<columns).map { index in
                sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }

    // MARK: - 谚文音节

    private static let base = 0xAC00

    /// 초성 / 중성 / 종성
    private static func split(_ character: Character) -> (Int, Int, Int)? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return nil }
        let code = Int(scalar.value) - base
        guard code >= 0, code < 11172 else { return nil }
        return (code / 588, (code / 28) % 21, code % 28)
    }

    private static func syllable(_ cho: Int, _ jung: Int, _ jong: Int = 0) -> String {
        String(UnicodeScalar(base + (cho * 21 + jung) * 28 + jong)!)
    }

    /// 变形时两个元音会并成一个，这里反着拆回去。
    /// 봐→보(ㅗ+아)、줘→주(ㅜ+어)、돼→되(ㅚ+어)、려→리(ㅣ+어)、해→하(ㅏ+여)、
    /// 써→쓰、파→프（后两个是 ㅡ 脱落）
    private static let unmerge: [Int: Int] = [9: 8, 14: 13, 10: 11, 6: 20, 1: 0, 4: 18, 0: 18]

    private static let jongL = 8, jongD = 7, jongS = 19, jongB = 17
    private static let jongH = 27, jongSS = 20, jongN = 4

    /// 词干后面接的是哪一类词尾。**不规则变化是有条件的** —— 条件就是这个：
    ///
    /// - `.vowel` 어/아 类 —— ㅡ 脱落、ㅂ、ㄷ、ㅅ、르 不规则都在这儿发生
    /// - `.eu` 으 类 —— ㄷ、ㅅ、ㅂ 会变，但**ㅡ 脱落和 르 不规则不会**
    /// - `.consonant` 直接贴上去的（는/고/습니다/冠形 ㄴ）—— 只有 ㄹ 脱落
    ///
    /// 不分类的话就会出现 `걸으면` 顺出 `거르다`（르 不规则在 으 前根本不发生）、
    /// `써도` 顺出 `썰다`（ㄹ 脱落在 도 前也不发生）这种错。
    enum After { case vowel, eu, consonant, any }

    /// 给一个词干和它后面词尾的类别，推出可能的词典形。
    static func lemmaCandidates(_ stem: String, after: After = .any) -> Set<String> {
        var out: Set<String> = []
        guard let last = stem.last, let (cho, jung, jong) = split(last) else { return [stem] }
        let head = String(stem.dropLast())
        let any = after == .any
        // 不切词尾时，这一段本身就可能是个词（名词、副词）
        if any { out.insert(stem) }
        out.insert(stem + "다")                    // 规则变化：词干原样

        // 过去时的 ㅆ 并进了词干音节，后面接什么都可能：갔→가、했→해→하
        if jong == jongSS {
            let bare = head + syllable(cho, jung)
            out.insert(bare + "다")
            if let merged = unmerge[jung] { out.insert(head + syllable(cho, merged) + "다") }
        }

        if jong == 0 {
            // 元音缩合与 ㅡ 脱落。**不看后面接什么** —— 缩合是词干表面已经发生的事，
            // `써도` 的 `써` 里已经含着一个 어，和后面那个 `도` 无关。
            if let merged = unmerge[jung] { out.insert(head + syllable(cho, merged) + "다") }
            // ㅂ 不规则：와/워 整个是词尾变来的，连音节一起去掉，前一个字补 ㅂ
            if any || after == .vowel {
                if jung == 9 || jung == 14, let previous = head.last,
                   let (pcho, pjung, pjong) = split(previous), pjong == 0 {
                    out.insert(String(head.dropLast()) + syllable(pcho, pjung, jongB) + "다")
                }
            }
            // ㅅ 不规则（나아→낫다、지어→짓다）：어/아 和 으 前都发生
            if any || after == .vowel || after == .eu {
                out.insert(head + syllable(cho, jung, jongS) + "다")
            }
            // ㄹ 脱落还原（사는→살다、여는→열다）：는/ㄴ/ㅂ니다 这类前面才掉
            if any || after == .consonant {
                out.insert(head + syllable(cho, jung, jongL) + "다")
            }
            // ㅎ 不规则（하얀→하얗다）：冠形 ㄴ 前
            if any || after == .consonant {
                out.insert(head + syllable(cho, jung, jongH) + "다")
            }
        }

        if jong == jongL {
            // ㄷ 不规则（들어→듣다、걸으면→걷다）：어/아 和 으 前
            if any || after == .vowel || after == .eu {
                out.insert(head + syllable(cho, jung, jongD) + "다")
            }
            // 르 不规则（불러→부르다、몰라→모르다）：**只在 라/러 前**
            if any || after == .vowel {
                out.insert(head + syllable(cho, jung) + "르다")
            }
        }

        // 冠形词尾 -(으)ㄴ / -(으)ㄹ 也并进词干音节。「-에 대한」是最常用的句式之一，
        // 不拆的话 `대한` 只剩名词「大寒」。ㄹ 词干接冠形词尾时先掉 ㄹ：만들다→만든。
        if jong == jongN || jong == jongL {
            out.insert(head + syllable(cho, jung) + "다")
            if jong == jongN { out.insert(head + syllable(cho, jung, jongL) + "다") }
            if jong == jongN, let merged = unmerge[jung] {   // 하얀→하야→하얗다 走 ㅎ 那条
                out.insert(head + syllable(cho, merged, jongH) + "다")
            }
        }
        return out
    }

    /// 另起一个音节的词尾，以及它属于哪一类。
    /// （并进词干音节的那些 —— 过去时 ㅆ、冠形 ㄴ/ㄹ、元音缩合 —— 在
    /// `lemmaCandidates` 里按音节拆，不在这张表上。）
    ///
    /// 这张表**不需要完整**：它只负责把切口切准，切不中还有退前缀兜底。
    private static let endings: [(String, After)] = [
        // 으 类
        ("으십시오", .eu), ("으세요", .eu), ("으시면", .eu), ("으니까", .eu), ("으면서", .eu),
        ("으려고", .eu), ("으므로", .eu), ("으면", .eu), ("으니", .eu), ("으며", .eu),
        ("은데요", .eu), ("을까", .eu), ("을지", .eu), ("은", .eu), ("을", .eu),
        // 어/아 类
        ("었습니다", .vowel), ("았습니다", .vowel), ("였습니다", .vowel), ("겠습니다", .consonant),
        ("었어요", .vowel), ("았어요", .vowel), ("였어요", .vowel), ("겠어요", .consonant),
        ("어요", .vowel), ("아요", .vowel), ("여요", .vowel), ("어서", .vowel), ("아서", .vowel),
        ("여서", .vowel), ("어도", .vowel), ("아도", .vowel), ("어야", .vowel), ("아야", .vowel),
        ("어라", .vowel), ("아라", .vowel), ("잖아요", .vowel), ("잖아", .vowel),
        ("었다", .vowel), ("았다", .vowel), ("였다", .vowel), ("었어", .vowel), ("았어", .vowel),
        ("었지", .vowel), ("았지", .vowel), ("었", .vowel), ("았", .vowel), ("였", .vowel),
        ("러", .vowel), ("라", .vowel), ("어", .vowel), ("아", .vowel),
        // 直接贴上去的
        ("습니다", .consonant), ("습니까", .consonant), ("십시오", .consonant), ("세요", .consonant),
        ("는군요", .consonant), ("는데요", .consonant), ("는데", .consonant), ("는다", .consonant),
        ("는가", .consonant), ("는지", .consonant), ("자마자", .consonant), ("면서", .consonant),
        ("려고", .consonant), ("므로", .consonant), ("지만", .consonant), ("도록", .consonant),
        ("든지", .consonant), ("거나", .consonant), ("네요", .consonant), ("군요", .consonant),
        ("지요", .consonant), ("기는", .consonant), ("기가", .consonant), ("기를", .consonant),
        ("기에", .consonant), ("기도", .consonant), ("겠다", .consonant), ("겠", .consonant),
        ("면", .consonant), ("며", .consonant), ("고", .consonant), ("지", .consonant),
        ("서", .consonant), ("도", .consonant), ("게", .consonant), ("자", .consonant),
        ("니", .consonant), ("는", .consonant), ("던", .consonant), ("요", .consonant),
        ("죠", .consonant), ("기", .consonant), ("음", .consonant),
    ]

    /// 按词尾把查询词切开，得到「词干 + 后面接的是哪类词尾」。
    ///
    /// 走两轮 —— 韩语词尾是叠着的：`먹었어요` 要先脱 `어요` 得到 `먹었`，
    /// 再脱 `었` 才落到 `먹`。一轮只能脱一层。
    ///
    /// 单音节词尾算「弱切口」：`사도`（使徒）脱一个 `도` 就成了 `사다`。
    /// 所以整词本身查得到时，只认两个音节以上的词尾。
    private static func stems(of query: String, weak: Bool) -> [(String, After)] {
        var found: [(String, After)] = []
        var seen = Set<String>()
        var frontier = [query]
        for _ in 0..<2 {
            var next: [String] = []
            for stem in frontier {
                for (ending, after) in endings
                where (weak || ending.count >= 2) && stem.hasSuffix(ending)
                      && stem.count > ending.count {
                    let cut = String(stem.dropLast(ending.count))
                    if seen.insert(cut + "\u{1}" + String(describing: after)).inserted {
                        found.append((cut, after))
                        next.append(cut)
                    }
                }
            }
            frontier = next
        }
        return found
    }

    // MARK: - 查

    struct Match {
        var word: String
        /// 靠还原找到的（不是原样命中），页面上要说明一句
        var restored: Bool
    }

    /// 词条表和官方活用形索引一起查。
    ///
    /// **活用形命中后必须顺着它解析到词条** —— 返回活用形本身等于没还原。
    /// 这一条踩过：`읽는`、`없어요`、`가는` 全都停在活用形上，六个用例一起失败。
    private static func direct(_ db: OpaquePointer, _ word: String,
                               verbsOnly: Bool = false) -> [String] {
        let filter = verbsOnly ? "AND (pos LIKE '%동사%' OR pos LIKE '%형용사%')" : ""
        return rows(db, """
            SELECT DISTINCT word FROM entry WHERE word = ?1 \(filter)
            UNION
            SELECT DISTINCT e.word FROM form f JOIN entry e ON e.id = f.entry_id
            WHERE f.form = ?1 \(filter.replacingOccurrences(of: "pos", with: "e.pos"))
            """, [word], columns: 1).map { $0[0] }
    }

    /// 查询词 → 词典形。
    ///
    /// 原样命中就用原样的（`보고` 本身是名词「报告」）；同时**再跑一遍还原**，
    /// 因为它也可能是 `보다` 的连接形。两个都给，让人自己看 —— 这种同形
    /// 本地没有任何信号能判，硬选一个只会选错。
    static func lemmatize(_ db: OpaquePointer, _ query: String) -> [Match] {
        let out = direct(db, query).map { Match(word: $0, restored: false) }
        var seen = Set(out.map(\.word))

        /// - Parameter verbsOnly: 在词尾处切开得到的词干，只可能是用言。
        ///   不限制的话 `먹었어요` 会顺出名词「먹」（墨），`걸으면` 顺出「걸」。
        func restore(_ stem: String, after: After = .any, verbsOnly: Bool = false) -> [Match] {
            var round: [Match] = []
            for candidate in lemmaCandidates(stem, after: after).sorted() {
                for word in direct(db, candidate, verbsOnly: verbsOnly)
                where seen.insert(word).inserted {
                    round.append(Match(word: word, restored: true))
                }
            }
            return round
        }

        // 按语法切：先看这个词是由哪个词尾结尾的，在那儿断开再还原词干。
        // 整词查到了也照样做一遍 —— 同形太常见：`대한` 既是名词「大寒」，
        // 也是「-에 대한」里 `대하다` 的冠形词形，后者才是句子里几乎必然的那个。
        var byGrammar: [Match] = []
        // 并进音节的词尾（过去时 ㅆ、冠形 ㄴ/ㄹ、元音缩合）在原词上就能拆
        byGrammar += restore(query, after: .any, verbsOnly: !out.isEmpty)
        for (stem, after) in stems(of: query, weak: out.isEmpty) {
            byGrammar += restore(stem, after: after, verbsOnly: true)
        }
        if !out.isEmpty || !byGrammar.isEmpty { return out + byGrammar }

        // 词尾表没覆盖到 —— 退着找词干兜底。词尾永远列不全，
        // 这一层保证「表里没有的写法」不至于查不到，代价是可能带出噪音。
        let characters = Array(query)
        for length in stride(from: characters.count - 1, through: 1, by: -1) {
            let round = restore(String(characters[0..<length]))
            if !round.isEmpty { return out + round }
        }
        return out
    }

    /// 中文/英文反查。
    ///
    /// 库里的 `fts_zh` 是 trigram 索引，**查询词不足 3 个字符时一条都匹配不到**
    /// （实测「树木」= 0 条，「树木，」= 6 条）。查词最常见的恰恰是一两个字，
    /// 所以这里走 LIKE —— 7.5 万义项实测 11 毫秒，没有用索引的必要。
    private static func reverse(_ db: OpaquePointer, _ query: String) -> [String] {
        // 排序看的是**查询词落在对译词的什么位置**，不是词长。
        // 对译词是「树，树木」这种逗号分隔的列表：整项相等最好，
        // 其次是作为完整一项出现，最后才是「松树」这种嵌在别的词里面的。
        // 只按词长排的话，查「树」会把单音节的 솔（松树）顶到 나무 前面。
        rows(db, """
            SELECT e.word,
                   MIN(CASE WHEN s.zh_word = ?1 OR s.en_word = ?1 THEN 0
                            WHEN s.zh_word LIKE ?1 || '，%' THEN 1
                            WHEN s.zh_word LIKE '%，' || ?1 THEN 1
                            WHEN s.zh_word LIKE '%，' || ?1 || '，%' THEN 1
                            ELSE 2 END) AS place,
                   MIN(CASE e.level WHEN '초급' THEN 0 WHEN '중급' THEN 1
                                    WHEN '고급' THEN 2 ELSE 3 END) AS lv
            FROM sense s JOIN entry e ON e.id = s.entry_id
            WHERE s.zh_word LIKE ?2 OR s.en_word LIKE ?2
            GROUP BY e.word ORDER BY place, lv, length(e.word) LIMIT 40
            """, [query, "%\(query)%"], columns: 3).map { $0[0] }
    }

    /// 什么都没查到时给点线索：以它开头的词
    private static func prefixed(_ db: OpaquePointer, _ query: String) -> [String] {
        rows(db, "SELECT DISTINCT word FROM entry WHERE word LIKE ? ORDER BY length(word) LIMIT 20",
             ["\(query)%"], columns: 1).map { $0[0] }
    }

    // MARK: - 取词条

    private struct Sense {
        var zhWord = "", zhDef = "", defKo = "", note = ""
        var examples: [String] = []
    }

    private struct Entry {
        var word = "", homonym = "", hanja = "", pos = "", unit = "", level = "", pron = ""
        var senses: [Sense] = []
        var related: [(String, String)] = []
    }

    private static func entries(_ db: OpaquePointer, word: String) -> [Entry] {
        rows(db, """
            SELECT id, word, IFNULL(homonym,''), IFNULL(hanja,''), IFNULL(pos,''),
                   IFNULL(unit,''), IFNULL(level,''), IFNULL(pron,'')
            FROM entry WHERE word = ?
            ORDER BY CASE level WHEN '초급' THEN 0 WHEN '중급' THEN 1 WHEN '고급' THEN 2 ELSE 3 END,
                     CAST(IFNULL(homonym,'0') AS INTEGER)
            """, [word], columns: 8).map { row in
            var entry = Entry(word: row[1], homonym: row[2], hanja: row[3], pos: row[4],
                              unit: row[5], level: row[6], pron: row[7])
            let id = Int(row[0]) ?? 0
            entry.senses = rows(db, """
                SELECT id, IFNULL(zh_word,''), IFNULL(zh_def,''), IFNULL(def_ko,''), IFNULL(note,'')
                FROM sense WHERE entry_id = ? ORDER BY ord
                """, [id], columns: 5).map { senseRow in
                var sense = Sense(zhWord: senseRow[1], zhDef: senseRow[2],
                                  defKo: senseRow[3], note: senseRow[4])
                // 例句总共 65 万条，每个义项全取会把页面压垮，取前三条够看用法了
                sense.examples = rows(db, "SELECT text FROM example WHERE sense_id = ? LIMIT 3",
                                      [Int(senseRow[0]) ?? 0], columns: 1).map { $0[0] }
                return sense
            }
            entry.related = rows(db, "SELECT IFNULL(kind,''), word FROM related WHERE entry_id = ?",
                                 [id], columns: 2).map { ($0[0], $0[1]) }
            return entry
        }
    }

    // MARK: - 出页面

    /// 查一次并渲染成 HTML，返回缓存文件的 URL。
    /// 放在配置目录下 —— 页面上点词要往回发消息，那条通道只认这个目录里的页面。
    static func page(database: URL, query: String, name: String) -> URL? {
        let target = directory.appendingPathComponent("\(NotesLibrary.stableHash(database.path)).html")
        let html: String
        if let db = open(database.path) {
            html = render(db: db, query: query, name: name, source: database)
        } else {
            html = problem(name: name, source: database)
        }
        try? html.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    private static var directory: URL {
        let dir = ConfigStore.directory.appendingPathComponent("krdict", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 词库页面自己的输入框。
    ///
    /// 窗口顶上那个查询框是**所有词典共用**的，敲下去查的是当前选中的那一本；
    /// 这里这个只查词库，而且韩中双向都认 —— 想连着查几个词时不用惦记选没选对。
    private static func searchBar(_ query: String) -> String {
        """
        <div class="find">
          <input id="kq" type="search" value="\(esc(query))"
                 placeholder="\(esc(t("krdict.searchHint")))">
          <button id="kgo">\(t("home.lookup"))</button>
        </div>
        """
    }

    private static func render(db: OpaquePointer, query: String, name: String, source: URL) -> String {
        let hangul = query.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }
        let matches = hangul ? lemmatize(db, query)
                             : reverse(db, query).map { Match(word: $0, restored: false) }

        var body = ""
        if matches.isEmpty {
            let hints = prefixed(db, query)
            body = """
            <p class="none">\(t("krdict.noHit", esc(query)))</p>
            \(hints.isEmpty ? "" : "<p class=\"hint\">\(t("krdict.tryThese"))<br>"
                + hints.map { "<a class=\"w\" href=\"#\" data-w=\"\(esc($0))\">\(esc($0))</a>" }
                       .joined(separator: " ") + "</p>")
            """
        }
        for match in matches.prefix(12) {
            for entry in entries(db, word: match.word) { body += card(entry, match: match, query: query) }
        }

        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style></head><body>
        <header><h1>\(esc(query))</h1>
        <span class="src">\(esc(name)) · \(t("krdict.offline"))</span></header>
        \(searchBar(query))
        \(body)
        <footer>\(t("krdict.credit"))</footer>
        <script>\(script)</script></body></html>
        """
    }

    private static func card(_ entry: Entry, match: Match, query: String) -> String {
        var chips = ""
        if !entry.pos.isEmpty { chips += "<span class=\"chip\">\(esc(entry.pos))</span>" }
        if !entry.unit.isEmpty && entry.unit != "단어" {
            chips += "<span class=\"chip unit\">\(esc(entry.unit))</span>"
        }
        if !entry.level.isEmpty { chips += "<span class=\"chip lv\">\(esc(entry.level))</span>" }

        var head = "<span class=\"word\">\(esc(entry.word))</span>"
        if !entry.homonym.isEmpty { head += "<sup>\(esc(entry.homonym))</sup>" }
        if !entry.hanja.isEmpty { head += "<span class=\"hanja\">\(esc(entry.hanja))</span>" }
        if !entry.pron.isEmpty { head += "<span class=\"pron\">[\(esc(entry.pron))]</span>" }

        var senses = ""
        for (index, sense) in entry.senses.enumerated() {
            var block = "<li>"
            if !sense.zhWord.isEmpty { block += "<b>\(esc(sense.zhWord))</b>" }
            if !sense.zhDef.isEmpty { block += "<span class=\"zh\">\(esc(sense.zhDef))</span>" }
            if !sense.defKo.isEmpty { block += "<div class=\"ko\">\(esc(sense.defKo))</div>" }
            if !sense.note.isEmpty { block += "<div class=\"note\">\(esc(sense.note))</div>" }
            for example in sense.examples {
                block += "<div class=\"ex\">\(esc(example))</div>"
            }
            block += "</li>"
            senses += block
            if index >= 7 { break }   // 极少数词有二十多个义项，翻不动
        }

        var related = ""
        let groups = Dictionary(grouping: entry.related, by: \.0)
        for (kind, words) in groups.sorted(by: { $0.key < $1.key }) {
            related += "<div class=\"rel\"><span>\(esc(kind))</span>"
                + words.map { "<a class=\"w\" href=\"#\" data-w=\"\(esc($0.1))\">\(esc($0.1))</a>" }
                       .joined(separator: "")
                + "</div>"
        }

        let via = match.restored
            ? "<div class=\"via\">\(t("krdict.restored", esc(query), esc(entry.word)))</div>" : ""
        return """
        <article>\(via)
        <div class="head">\(head)\(chips)
        <button class="say" data-t="\(esc(entry.word))">\u{1F50A}</button></div>
        <ol>\(senses)</ol>\(related)</article>
        """
    }

    private static func problem(name: String, source: URL) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>\(css)</style></head><body>
        <header><h1>\(esc(name))</h1></header>
        <p class="none">\(t("krdict.cantOpen"))</p>
        <p class="hint">\(esc(source.path))</p></body></html>
        """
    }

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 点词换查、点喇叭朗读。两件事都发回 App 做 —— 页面是 file://，
    /// 自己既查不了库也发不出声。
    private static let script = """
    const box = document.getElementById('kq');
    function find() {
      const text = box.value.trim();
      if (!text) { box.focus(); return; }
      window.webkit.messageHandlers.quickdict.postMessage({action: 'search', text: text});
    }
    if (box) {
      box.addEventListener('keydown', e => { if (e.key === 'Enter') find(); });
      document.getElementById('kgo').onclick = find;
      // 光标停在词尾，接着改比重打快
      box.addEventListener('focus', () => box.setSelectionRange(box.value.length, box.value.length));
    }
    document.addEventListener('click', function (event) {
      const word = event.target.closest('.w');
      if (word) { event.preventDefault();
        window.webkit.messageHandlers.quickdict.postMessage(
          {action: 'search', text: word.dataset.w}); return; }
      const say = event.target.closest('.say');
      if (say) { window.webkit.messageHandlers.quickdict.postMessage(
          {action: 'speak', text: say.dataset.t}); }
    });
    """

    private static let css = """
    :root { color-scheme: light dark; --fg:#1d1d1f; --dim:#86868b; --line:#e5e5e7;
            --bg:#fff; --card:#f5f5f7; --accent:#0b6bcb; --warm:#c25e00; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#f5f5f7; --dim:#98989d; --line:#38383a; --bg:#1c1c1e;
              --card:#2c2c2e; --accent:#6cb2ff; --warm:#ff9f45; }
    }
    * { box-sizing:border-box; }
    body { margin:0; padding:20px 24px 40px; background:var(--bg); color:var(--fg);
           font:15px/1.65 -apple-system,"PingFang SC","Apple SD Gothic Neo",sans-serif; }
    header { display:flex; align-items:baseline; gap:10px; flex-wrap:wrap;
             padding-bottom:10px; border-bottom:1px solid var(--line); }
    h1 { font-size:22px; margin:0; letter-spacing:-.3px; }
    .src { font-size:11.5px; color:var(--dim); }
    article { margin:18px 0; padding:14px 16px; background:var(--card); border-radius:12px; }
    .via { font-size:11.5px; color:var(--warm); margin-bottom:8px; }
    .head { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
    .word { font-size:20px; font-weight:650; }
    sup { font-size:11px; color:var(--dim); }
    .hanja { color:var(--dim); font-size:14px; }
    .pron { color:var(--dim); font-size:12.5px; }
    .chip { font-size:11px; padding:1px 7px; border-radius:20px;
            border:1px solid var(--line); color:var(--dim); }
    .chip.lv { border-color:var(--accent); color:var(--accent); }
    .chip.unit { border-color:var(--warm); color:var(--warm); }
    .say { margin-left:auto; border:none; background:none; cursor:pointer;
           font-size:15px; opacity:.55; padding:2px 4px; }
    .say:hover { opacity:1; }
    ol { margin:10px 0 0; padding-left:20px; }
    li { margin:0 0 10px; }
    li b { font-size:15.5px; }
    .zh { color:var(--fg); margin-left:6px; }
    .ko { color:var(--dim); font-size:13px; margin-top:2px; }
    .note { color:var(--warm); font-size:12.5px; margin-top:2px; }
    .ex { color:var(--dim); font-size:13px; margin-top:3px; padding-left:9px;
          border-left:2px solid var(--line); }
    .rel { margin-top:8px; font-size:13px; display:flex; gap:6px;
           align-items:baseline; flex-wrap:wrap; }
    .rel span { color:var(--dim); font-size:11.5px; }
    .w { color:var(--accent); text-decoration:none; cursor:pointer;
         padding:1px 6px; border-radius:6px; background:rgba(127,127,127,.12); }
    .find { display:flex; gap:7px; margin:14px 0 2px; }
    #kq { flex:1; min-width:0; font:14px -apple-system,"PingFang SC","Apple SD Gothic Neo",sans-serif;
          padding:7px 12px; border-radius:9px; border:1px solid var(--line);
          background:var(--card); color:var(--fg); -webkit-appearance:none; appearance:none; }
    #kq:focus { outline:2px solid var(--accent); outline-offset:-1px; }
    #kgo { font:14px -apple-system,"PingFang SC",sans-serif; color:var(--fg); cursor:pointer;
           padding:0 18px; border:1px solid var(--line); background:var(--card);
           border-radius:9px; -webkit-appearance:none; appearance:none; }
    #kgo:hover { border-color:var(--accent); }
    .none { margin:24px 0 8px; font-size:15px; }
    .hint { color:var(--dim); font-size:13px; line-height:2.1; }
    footer { margin-top:28px; padding-top:12px; border-top:1px solid var(--line);
             font-size:11.5px; color:var(--dim); }
    """
}
