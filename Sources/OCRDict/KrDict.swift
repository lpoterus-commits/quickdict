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

    /// 给一个词干前缀，生成它可能对应的词典形。
    /// 除了前缀本身（名词就是这样），其余候选一律带 `다` —— 这一条让误命中很难发生：
    /// `나무` 只会生成 `나물다`、`나뭇다` 这类不存在的词，不会撞上真实词条 `나물`。
    static func lemmaCandidates(_ stem: String) -> Set<String> {
        var out: Set<String> = [stem]
        guard let last = stem.last, let (cho, jung, jong) = split(last) else { return out }
        let head = String(stem.dropLast())
        out.insert(stem + "다")

        // 过去时的 ㅆ 并进了词干音节：갔→가、했→해→하、왔→와→오
        if jong == jongSS {
            out.insert(head + syllable(cho, jung) + "다")
            if let merged = unmerge[jung] { out.insert(head + syllable(cho, merged) + "다") }
        }

        if jong == 0 {
            if let merged = unmerge[jung] { out.insert(head + syllable(cho, merged) + "다") }
            out.insert(head + syllable(cho, jung, jongL) + "다")   // ㄹ 脱落还原：사→살다
            out.insert(head + syllable(cho, jung, jongS) + "다")   // ㅅ 不规则：나→낫다
            out.insert(head + syllable(cho, jung, jongH) + "다")   // ㅎ 不规则：하야→하얗다
            // ㅂ 不规则：도와→돕다、추워→춥다。와/워 整个是词尾变来的，连音节一起去掉
            if jung == 9 || jung == 14, let previous = head.last,
               let (pcho, pjung, pjong) = split(previous), pjong == 0 {
                out.insert(String(head.dropLast()) + syllable(pcho, pjung, jongB) + "다")
            }
        }

        if jong == jongL {
            out.insert(head + syllable(cho, jung, jongD) + "다")   // ㄷ 不规则：걸→걷다
            out.insert(head + syllable(cho, jung) + "르다")         // 르 不规则：몰→모르다
        }

        // 冠形词尾 -(으)ㄴ / -(으)ㄹ 和过去时的 ㅆ 一样，并进了词干最后一个音节。
        // 「-에 대한」是最常见的句式之一，不拆的话 `대한` 只剩名词「大寒」那个义项。
        if jong == jongN || jong == jongL {
            out.insert(head + syllable(cho, jung) + "다")           // 대한→대하다、큰→크다
        }
        return out
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
    private static func direct(_ db: OpaquePointer, _ word: String) -> [String] {
        rows(db, """
            SELECT DISTINCT word FROM entry WHERE word = ?1
            UNION
            SELECT DISTINCT e.word FROM form f JOIN entry e ON e.id = f.entry_id WHERE f.form = ?1
            """, [word], columns: 1).map { $0[0] }
    }

    /// 查询词 → 词典形。
    ///
    /// 原样命中就用原样的（`보고` 本身是名词「报告」）；同时**再跑一遍还原**，
    /// 因为它也可能是 `보다` 的连接形。两个都给，让人自己看 —— 这种同形
    /// 本地没有任何信号能判，硬选一个只会选错。
    static func lemmatize(_ db: OpaquePointer, _ query: String) -> [Match] {
        var out = direct(db, query).map { Match(word: $0, restored: false) }
        var seen = Set(out.map(\.word))

        let characters = Array(query)
        for length in stride(from: characters.count, through: 1, by: -1) {
            let stem = String(characters[0..<length])
            // 原样那一层已经查过了，别重复
            if length == characters.count && !out.isEmpty && stem == query { continue }
            var round: [Match] = []
            for candidate in lemmaCandidates(stem).sorted() {
                for word in direct(db, candidate) where !seen.contains(word) {
                    seen.insert(word)
                    round.append(Match(word: word, restored: true))
                }
            }
            if !round.isEmpty { out += round; break }
        }
        return out
    }

    // MARK: - 整句分词

    /// 切句子时要丢掉的成分。助词和词尾用断词还原那张表（同一套知识，一处维护），
    /// 这里补的是**单音节的连接词尾** —— 它们同时也是合法词条
    /// （`어` 是叹词、`자` 是尺），切碎后会以「词」的身份冒出来。
    private static let extraStop: Set<String> = [
        "어", "아", "여", "워", "게", "기", "자", "라", "냐", "니", "랑", "들",
    ]

    private static var stopWords: Set<String> { LineJoiner.koreanParticles.union(extraStop) }

    struct Segment {
        var piece: String       // 原文里的那一段
        var words: [Match]      // 它对应的词典形
    }

    struct Reading {
        var segments: [Segment] = []
        /// 一个词都对不上的片段。**说出来比装作没有强** —— 人名、外来语、
        /// 专业词本来就不在这本基础词典里，看见「클라라 词库里没有」
        /// 才知道是词库的边界，而不是自己查错了。
        var unknown: [String] = []
    }

    /// 一次查一句话或一串词：切成词，每个词各自还原。
    ///
    /// 用最长匹配 —— 从每个位置往后取尽量长的一段，能查到就收下并跳过去，
    /// 查不到就退一个字。词典本身就是词表，所以切分的依据是「库里有没有这个词」，
    /// 不需要另外训练分词器。
    ///
    /// 两条降噪规则，都是实测出来的：
    /// - **单音节只认「词条本身就长这样」的**。靠活用形索引或合成拐过来的一个字
    ///   （`까`→까다、`스`→슬다）几乎全是切碎产生的假象。
    /// - **助词和词尾整个丢掉**，否则一句话里一半的结果是 은/는/이/가。
    static func segment(_ db: OpaquePointer, _ query: String) -> Reading {
        var reading = Reading()
        var seen = Set<String>()
        let stop = stopWords

        for token in query.split(whereSeparator: { !("\u{AC00}"..."\u{D7A3}").contains($0) }) {
            let characters = Array(token)
            var index = 0
            // 攒着还没解释掉的字。助词、被压掉的残片本身是「已知」的，
            // **但前面已经有对不上的字时，它们多半也是那个词的一部分** ——
            // 「클라라」里的 `라` 会命中音名 la，不这样处理就把人名拆没了。
            var pending: [Character] = []
            var abuts = false                  // 上一段就贴在这儿结束（中间没跳过字）

            func flushPending() {
                // 一个字的残片没有信息量，两个字起才值得报
                if pending.count >= 2 { reading.unknown.append(String(pending)) }
                pending = []
            }

            while index < characters.count {
                var taken: (Int, String, [Match])?
                // 8 个音节足够覆盖最长的复合词，再长就是没切开的句子了
                for length in stride(from: min(8, characters.count - index), through: 1, by: -1) {
                    let piece = String(characters[index..<(index + length)])
                    let hits = resolve(db, piece)
                    if !hits.isEmpty { taken = (length, piece, hits); break }
                }
                guard let (length, piece, hits) = taken else {
                    pending.append(characters[index])
                    index += 1
                    abuts = false
                    continue
                }
                let range = characters[index..<(index + length)]
                index += length
                let touching = abuts
                abuts = true
                if stop.contains(piece) {
                    if !pending.isEmpty { pending += range }
                    continue
                }
                // 紧贴在上一段后面的单音节，多半是复合词被切开的尾巴，不是词。
                // 「수도회」库里没有 → 切成 수도 + 회，那个「회」是生鱼片，纯属误导。
                // 中间跳过字的不算（「후리가케밥」的 밥 前面隔着没认出来的 가케，是真的词）。
                if length == 1 && touching {
                    if !pending.isEmpty { pending += range }
                    continue
                }
                let words = hits.filter { match in
                    if length == 1 && (match.restored || match.word != piece) { return false }
                    return !stop.contains(match.word) && seen.insert(match.word).inserted
                }
                if words.isEmpty {
                    if !pending.isEmpty { pending += range }
                    continue
                }
                flushPending()
                reading.segments.append(Segment(piece: piece, words: words))
            }
            flushPending()
        }
        return reading
    }

    /// 一段文字对应的词典形。
    ///
    /// **直接查到了也照样再还原一次** —— 同形太常见：`대한` 既是名词「大寒」，
    /// 也是「-에 대한」里 `대하다` 的冠形词形，后者才是句子里几乎必然的那个。
    /// 只给前者等于答错。和单词查询里对 `보고` 的处理是同一条原则：两个都给。
    ///
    /// 单音节不做还原 —— 噪音全是从那儿来的（`까`→까다、`스`→슬다）。
    private static func resolve(_ db: OpaquePointer, _ piece: String) -> [Match] {
        var out: [Match] = []
        var seen = Set<String>()
        for word in direct(db, piece) where seen.insert(word).inserted {
            out.append(Match(word: word, restored: false))
        }
        guard piece.count >= 2 else { return out }
        // 「词干 + 다」是唯一一个**不带任何变形迹象**的候选 —— 它假设这一段本身就是词干。
        // 这一段已经查到词了的话，这种猜测就不作数：`새우`（虾）会凭空多出 `새우다`（熬夜）。
        // 靠拆 ㅆ / ㄴ / ㄹ 或不规则还原出来的照收，那些都有迹象：`대한` → `대하다`。
        let bare = piece + "다"
        for candidate in lemmaCandidates(piece).sorted() {
            if !out.isEmpty && candidate == bare { continue }
            for word in direct(db, candidate) where seen.insert(word).inserted {
                out.append(Match(word: word, restored: true))
            }
        }
        return out
    }

    /// 词表里每行显示的一句话：词性 + 中文对译。
    ///
    /// 取**前两条**义项，不是第一条 —— 词典自己的义项顺序不一定把常用的排在前面
    /// （`만나다` 的第一条是「交汇」，「见面」在第二条）。给两条，一眼就能认出是哪个词。
    private static func brief(_ db: OpaquePointer, _ word: String) -> (String, String) {
        let found = rows(db, """
            SELECT IFNULL(e.pos,''), IFNULL(s.zh_word,''), IFNULL(s.zh_def,'')
            FROM entry e LEFT JOIN sense s ON s.entry_id = e.id WHERE e.word = ?
            ORDER BY CASE e.level WHEN '초급' THEN 0 WHEN '중급' THEN 1
                                  WHEN '고급' THEN 2 ELSE 3 END, s.ord LIMIT 2
            """, [word], columns: 3)
        guard let first = found.first else { return ("", "") }
        let glosses = found.map { $0[1].isEmpty ? $0[2] : $0[1] }.filter { !$0.isEmpty }
        return (first[0], glosses.joined(separator: " / "))
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

    private static func render(db: OpaquePointer, query: String, name: String, source: URL) -> String {
        let hangul = query.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }

        // 查的是一串词还是一个词？**看切出来几段，不看查到几个词** ——
        // `걸어서` 一段就能查到 걷다/걸다 两个词，那是同形不是两个词，
        // 按词数判会把它误当成句子。
        if hangul {
            let reading = segment(db, query)
            if reading.segments.count >= 2 {
                return wordList(db: db, query: query, name: name, reading: reading)
            }
        }

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
        \(body)
        <footer>\(t("krdict.credit"))</footer>
        <script>\(script)</script></body></html>
        """
    }

    /// 整句/多词的结果：一行一个词，点开才看详细。
    /// 一句话里十几个词，每个都摊开释义和例句的话，翻不到底。
    private static func wordList(db: OpaquePointer, query: String, name: String,
                                 reading: Reading) -> String {
        var rows = ""
        var count = 0
        for segment in reading.segments {
            for match in segment.words {
                count += 1
                let (pos, gloss) = brief(db, match.word)
                // 还原过的把原文那一段也显示出来，好对上句子里的哪个位置
                let from = match.restored || segment.piece != match.word
                    ? "<span class=\"from\">\(esc(segment.piece))</span>" : ""
                rows += """
                <a class="row w" href="#" data-w="\(esc(match.word))">\(from)
                <b>\(esc(match.word))</b>
                \(pos.isEmpty ? "" : "<span class=\"chip\">\(esc(pos))</span>")
                <span class="gloss">\(esc(gloss))</span></a>
                """
            }
        }
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style></head><body>
        <header><h1>\(esc(query))</h1>
        <span class="src">\(esc(name)) · \(t("krdict.offline"))</span></header>
        <p class="lead">\(t("krdict.segmented", count))</p>
        <div class="list">\(rows)</div>
        \(reading.unknown.isEmpty ? "" : "<p class=\"hint\">\(t("krdict.unknown"))"
            + reading.unknown.map { "<span class=\"miss\">\(esc($0))</span>" }.joined(separator: " ")
            + "</p>")
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
    .lead { color:var(--dim); font-size:12.5px; margin:14px 0 10px; }
    .list { display:flex; flex-direction:column; gap:2px; }
    .row { display:flex; align-items:baseline; gap:8px; padding:8px 12px;
           border-radius:9px; text-decoration:none; color:var(--fg); background:none; }
    .row:hover { background:var(--card); }
    .row b { font-size:15.5px; min-width:5.2em; }
    .row .from { font-size:11.5px; color:var(--warm); min-width:4.5em; text-align:right; }
    .row .gloss { color:var(--dim); font-size:13.5px; }
    .miss { color:var(--warm); padding:1px 6px; border-radius:6px;
            background:rgba(127,127,127,.12); }
    .none { margin:24px 0 8px; font-size:15px; }
    .hint { color:var(--dim); font-size:13px; line-height:2.1; }
    footer { margin-top:28px; padding-top:12px; border-top:1px solid var(--line);
             font-size:11.5px; color:var(--dim); }
    """
}
