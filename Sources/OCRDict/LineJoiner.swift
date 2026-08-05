import AppKit
import CoreGraphics
import CoreServices
import Foundation

/// 把 OCR 出来的多行拼回连续文本，处理「一个词被换行切成两半」的情况。
///
/// 这件事没有一个 API 能直接解决，得组合三种信号：
///
/// 1. **几何**：这行是顶满右边缘（被挤断的）还是空出一截（自然结束）。
///    可靠地区分「换行」和「段落/句子结束」，但**区分不了顶满的行里断点落在空格还是词中间** ——
///    CJK 默认允许在任意字之间断行，两种情况的像素表现一样。
/// 2. **连字符**：拉丁文的 `inter-\nnational`。确定性最高，优先处理。
/// 3. **语言学**：拉丁文用系统拼写检查（可靠）；韩语用「下一行开头是不是悬空的助词/词尾」判断
///    （macOS 的韩语拼写检查太宽松、分词器又不做形态素切分，只能走这条启发式）。
enum LineJoiner {
    /// 韩语助词与常见词尾。出现在行首且孤立时，几乎必然是上一行末尾那个词被切开了。
    private static let danglingParticles: Set<String> = [
        "은", "는", "이", "가", "을", "를", "에", "의", "도", "만", "과", "와", "로",
        "으로", "에서", "에게", "한테", "부터", "까지", "처럼", "보다", "라고", "이라고",
        "로서", "로써", "으로서", "으로써", "에는", "에도", "에만", "에서는", "이라도",
        "라도", "마저", "조차", "만큼", "대로", "커녕",
        "라는", "이라는", "하고", "이나", "나", "야", "여", "며", "면", "서", "고", "지",
        "다", "다.", "요", "죠", "네", "니다", "습니다", "입니다", "했다", "한다", "이다",
        // 高频词尾。落在行首几乎都是上一行词干被切开的后半截（온유|하며、시기|하지）
        "하며", "하지", "하고", "하는", "하여", "하면", "하니", "해서", "해도", "합니다",
        "되며", "되지", "되고", "된다", "되는", "이며", "으며", "으로", "스러운", "적인",
        // 名词化后缀 + 助词（그리움 被切成 그리|움은）
        "음은", "음을", "음이", "음의", "움은", "움을", "움이", "움의", "기는", "기를", "기가",
        // 动词变位词尾，永远黏在词干后面（약해|진다고）
        "진다", "진다고", "진다는", "집니다", "지고", "지만", "는데", "으니", "았다", "었다",
        "겠다", "려고", "면서", "도록", "니까", "아서", "어서",
    ]

    /// 少数能独立成词的单音节，别被当成悬空词尾
    private static let standaloneSyllables: Set<String> = [
        "나", "너", "그", "이", "저", "것", "수", "때", "곳", "말", "일", "안", "밖",
        "위", "앞", "뒤", "옆", "속", "중", "더", "못", "잘", "다", "또", "및", "등",
    ]

    struct Result {
        var text: String
        /// 合并了、但拆开写也讲得通的地方。`이성적인` 既可能是被切断的一个词，
        /// 也可能原文就是 `이 성적인` 两个词 —— 本地没有任何信号能分辨，只能标出来让人扫一眼。
        var ambiguous: [String]
    }

    static func joined(_ lines: [OCRLine]) -> Result {
        let cleaned = lines
            .map { OCRLine(text: $0.text.trimmingCharacters(in: .whitespaces), box: $0.box) }
            .filter { !$0.text.isEmpty }
        guard cleaned.count > 1 else {
            return Result(text: cleaned.first?.text ?? "", ambiguous: [])
        }
        var ambiguous: [String] = []

        let columnRight = cleaned.map(\.box.maxX).max() ?? 1
        let heights = cleaned.map(\.box.height).sorted()
        let medianHeight = heights[heights.count / 2]

        var result = cleaned[0].text
        for i in 1..<cleaned.count {
            let previous = cleaned[i - 1]
            let current = cleaned[i]

            // 行距明显变大 = 换段，保留换行
            let verticalGap = previous.box.minY - current.box.maxY
            if verticalGap > medianHeight * 0.9 {
                result += "\n" + current.text
                continue
            }

            result = merge(result, previous: previous, next: current,
                           columnRight: columnRight, ambiguous: &ambiguous)
        }
        return Result(text: result, ambiguous: ambiguous)
    }

    private static func merge(_ accumulated: String, previous: OCRLine, next: OCRLine,
                              columnRight: CGFloat, ambiguous: inout [String]) -> String {
        // 信号 2：连字符断词，确定性最高
        if let last = accumulated.last, last == "-" || last == "‐" || last == "\u{00AD}" {
            return String(accumulated.dropLast()) + next.text
        }

        guard let leftTail = accumulated.unicodeScalars.last,
              let rightHead = next.text.unicodeScalars.first
        else { return accumulated + next.text }

        // 信号 3 先行：悬空助词、单音节碎片这类语言学信号足够强，不用等几何表态
        if isHangul(leftTail), isHangul(rightHead) {
            let verdict = hangulVerdict(accumulated, next.text)
            if verdict.broken {
                if verdict.ambiguous {
                    let tail = String(accumulated.split(separator: " ").last ?? "")
                    let head = String(next.text.split(separator: " ", maxSplits: 1).first ?? "")
                    ambiguous.append(tail + head)
                }
                return accumulated + next.text
            }
        }

        // 信号 1：这行有没有顶满右边缘
        let charWidth = previous.box.width / CGFloat(max(1, previous.text.count))
        let gap = columnRight - previous.box.maxX
        guard gap < charWidth * 0.6 else {
            // 空出一截 = 断点落在空格上，或者本来就是句末
            return accumulated + " " + next.text
        }

        // 顶满 = 断点是被挤出来的，但断在空格上还是词中间，像素上看不出来。
        // 实测把韩语默认设成「不加空格」反而更差（21/33 vs 28/33）—— 断点落在词边界仍是多数，
        // 所以默认加空格，真正的断词交给上面的强信号兜。
        // 中日文没有词间空格，直接连。
        if isHangul(leftTail), isHangul(rightHead) { return accumulated + " " + next.text }
        if isHanOrKana(leftTail), isHanOrKana(rightHead) { return accumulated + next.text }
        if isLatin(leftTail), isLatin(rightHead) {
            return accumulated + (latinLooksBroken(accumulated, next.text) ? "" : " ") + next.text
        }
        return accumulated + " " + next.text
    }

    // MARK: - 韩语

    /// 强信号：任一命中就判定为一个词被切成了两半。
    /// ambiguous 表示「合是对的可能性更大，但拆开写也讲得通」—— 这种要标出来。
    private static func hangulVerdict(_ accumulated: String,
                                      _ nextLine: String) -> (broken: Bool, ambiguous: Bool) {
        let head = String(nextLine.split(separator: " ", maxSplits: 1).first ?? "")
        let tail = String(accumulated.split(separator: " ").last ?? "")
        guard !head.isEmpty else { return (false, false) }

        // 1. 下一行开头是孤立的助词/词尾（그리움 | 은 언제나）。黏着语素，不可能独立成词，确定。
        if danglingParticles.contains(head) { return (true, false) }

        // 2. 拼起来能在系统韩语词典里查到跨接缝的词（이 | 성적인 → 이성적）。
        //    这一条是唯一可能误判的：如果上半截本身也成词，那原文就有可能真是分开写的
        //    （이성적인 = 理性的，이 성적인 = 这个性方面的）。标出来。
        if dictionaryBridgesJunction(tail: tail, head: head) {
            return (true, hasDefinition(tail))
        }

        // 3. 下一行开头是不能独立成词的单音节（띄 | 어 쓰는）
        if head.count == 1, !standaloneSyllables.contains(head) { return (true, false) }
        // 4. 上一行末尾是单音节碎片。但要先确认下一行开头本身不成词 ——
        //    否则 `할 | 때` 这种两边都是正经词的会被误连成 `할때`。
        if tail.count == 1, !standaloneSyllables.contains(tail), !hasDefinition(head) {
            return (true, false)
        }
        return (false, false)
    }

    /// 把两半拼起来，看最长的成词前缀有没有**越过接缝**。
    ///
    /// `이` + `성적인` → 拼成 `이성적인`，词典里查到 `이성적`，长度 3 > 上一行末尾的 1 → 越过了 → 断词。
    /// `조용히` + `머물러` → `조용히머…` 查不到任何跨接缝的词 → 本来就是两个词。
    ///
    /// 实测这条判据零误判（不会把两个独立的词粘起来），代价是漏判——漏掉的交给上面的助词表兜。
    /// 依赖「词典」App 里启用了韩语词典；没启用的话这里恒返回 false，退化成纯启发式，不会出错。
    private static func dictionaryBridgesJunction(tail: String, head: String) -> Bool {
        guard !tail.isEmpty, !head.isEmpty else { return false }
        let merged = Array(tail + head)
        // 韩语词条极少超过接缝后 4 个音节，限一下查询次数
        let upper = min(merged.count, tail.count + 4)
        guard upper > tail.count else { return false }

        for length in stride(from: upper, through: tail.count + 1, by: -1) {
            if hasDefinition(String(merged[0..<length])) { return true }
        }
        return false
    }

    private static func hasDefinition(_ word: String) -> Bool {
        let range = CFRange(location: 0, length: word.utf16.count)
        guard let definition = DCSCopyTextDefinition(nil, word as CFString, range) else { return false }
        _ = definition.takeRetainedValue() // Copy 规则，拿到所有权后释放
        return true
    }

    // MARK: - 拉丁文
    // 英语拼写检查是真词典，能直接判断「拼起来是不是一个词」，比韩语那边可靠得多

    /// 拉丁文默认按词断行，所以只有「拼起来正好是个词」才判定为被切开。
    /// 英语拼写检查是真词典，这个判断比韩语那边可靠得多。
    private static func latinLooksBroken(_ accumulated: String, _ nextLine: String) -> Bool {
        let tail = String(accumulated.split(separator: " ").last ?? "")
        let head = String(nextLine.split(separator: " ").first ?? "")
        guard !tail.isEmpty, !head.isEmpty else { return false }
        let merged = (tail + head).trimmingCharacters(in: .punctuationCharacters)
        guard merged.count > 2 else { return false }
        return isSpelledCorrectly(merged)
    }

    private static func isSpelledCorrectly(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: "en",
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    // MARK: - 字符集判定

    private static func isHangul(_ s: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(s.value) || (0x1100...0x11FF).contains(s.value)
            || (0x3130...0x318F).contains(s.value)
    }

    private static func isHanOrKana(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
            || (0x3040...0x309F).contains(s.value) || (0x30A0...0x30FF).contains(s.value)
    }

    private static func isLatin(_ s: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value)
            || (0x00C0...0x024F).contains(s.value)
    }
}
