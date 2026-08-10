import Foundation
import NaturalLanguage

struct RouteResult {
    var language: String
    var confidence: Double
    /// true 表示判定不可靠，UI 上要提示用户可能需要手动切词典
    var ambiguous: Bool

    var displayName: String { LanguageNames.display(language) }
}

enum LanguageRouter {
    /// 使用拉丁字母的语言。只有落到这一类才需要跑统计式的语种识别。
    static let latinLanguages: Set<String> = [
        "en", "it", "fr", "de", "es", "pt", "nl", "sv", "da", "nb", "fi",
        "pl", "cs", "tr", "vi", "id", "ms", "ro", "hu", "ca", "hr", "sk",
        "sl", "lt", "lv", "et",
    ]

    static func route(_ text: String, config: AppConfig) -> RouteResult {
        // 第一步：按字符集硬路由。谚文/假名/汉字/西里尔都是确定性的，不需要猜。
        var hangul = 0, kana = 0, han = 0, cyrillic = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3040...0x309F, 0x30A0...0x30FF: kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: han += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A, 0x00C0...0x024F: latin += 1
            default: break
            }
        }

        if hangul > 0 { return RouteResult(language: "ko", confidence: 1, ambiguous: false) }
        if kana > 0 { return RouteResult(language: "ja", confidence: 1, ambiguous: false) }
        if han > 0 { return RouteResult(language: "zh", confidence: 1, ambiguous: false) }
        if cyrillic > latin && cyrillic > 0 {
            return RouteResult(language: "ru", confidence: 1, ambiguous: false)
        }
        guard latin > 0 else {
            return RouteResult(language: config.defaultLatinLanguage, confidence: 0, ambiguous: true)
        }

        // 第二步：拉丁字母。只在配置里真实用到的拉丁语种之间做选择，候选越少越准。
        let candidates = configuredLatinLanguages(config)
        guard candidates.count > 1 else {
            let only = candidates.first ?? config.defaultLatinLanguage
            return RouteResult(language: only, confidence: 1, ambiguous: false)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage($0) }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: candidates.count)

        guard let best = hypotheses.max(by: { $0.value < $1.value }) else {
            return RouteResult(language: config.defaultLatinLanguage, confidence: 0, ambiguous: true)
        }
        // 单词太短时统计识别基本是抛硬币，宁可回落到默认语言并把 ambiguous 打出来
        if best.value < config.latinConfidenceThreshold {
            return RouteResult(language: config.defaultLatinLanguage,
                               confidence: best.value, ambiguous: true)
        }
        return RouteResult(language: best.key.rawValue, confidence: best.value, ambiguous: false)
    }

    /// 从配置的词典列表里反推出「我关心哪些拉丁语种」
    static func configuredLatinLanguages(_ config: AppConfig) -> [String] {
        var result: [String] = []
        for site in config.dictionaries {
            for lang in site.languages where latinLanguages.contains(lang) && !result.contains(lang) {
                result.append(lang)
            }
        }
        return result
    }
}

enum DictRouter {
    /// 语言 -> 词典下标；找不到就用 "*" 兜底词典
    static func index(for language: String, in sites: [DictSite]) -> Int {
        if let i = sites.firstIndex(where: { $0.languages.contains(language) }) { return i }
        if let i = sites.firstIndex(where: { $0.languages.contains("*") }) { return i }
        return 0
    }

    /// 断网时的落点。
    ///
    /// 在线词典这时候一定是白屏，本地词库反而是唯一能出结果的 —— 所以自动顶上，
    /// 不用用户自己反应过来去切。联网状态下这个函数什么都不改。
    static func index(for language: String, in sites: [DictSite], online: Bool) -> Int {
        let normal = index(for: language, in: sites)
        guard !online, sites.indices.contains(normal) else { return normal }
        // 本来就是本地的，不用换
        if sites[normal].isDatabase || sites[normal].isNotes { return normal }
        if let local = sites.firstIndex(where: { $0.isDatabase }) { return local }
        if let local = sites.firstIndex(where: { $0.isNotes }) { return local }
        return normal
    }

    static func url(site: DictSite, query: String) -> URL? {
        let raw = query + (site.suffix ?? "")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let filled = site.url.replacingOccurrences(of: "{q}", with: encoded)
        // 网址模板本身也可能有非 ASCII —— 指向本地资料时路径里常带中文。
        return URL(string: filled) ?? URL(string: escapeNonASCII(filled))
    }

    /// 只转义非 ASCII 字符，`:` `/` `?` `#` 这些结构符号原样保留。
    /// 整串做 addingPercentEncoding 会把已编码的查询词二次转义。
    private static func escapeNonASCII(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            }
        }
        return out
    }
}

enum LanguageNames {
    /// 语言名跟随界面语言。查不到翻译就直接显示语言代码。
    static func display(_ code: String) -> String {
        for candidate in [code, String(code.prefix(2))] {
            let key = "lang.\(candidate)"
            let localized = t(key)
            if localized != key { return localized }
        }
        return code
    }
}
