import Foundation

/// 词典配置由**两个轴**决定：
///
/// - **母语**（`target`）—— 释义落在哪种语言。一次只有一个。
/// - **要查的外语**（`sources`）—— 你会遇到哪些语言的生词。可以多选。
///
/// 韩语走 Naver 的双语词典（质量最好，而且双向：读韩语查释义、写韩语反查说法）。
/// 其余语言走 Glosbe —— 它专做双语对，任意 X→Y 组合都有，正好补上 Naver 只做韩语对的空缺。
///
/// ## 加一种语言
///
/// 往 `targets` 里加一条就多一种母语，往 `selectableSources` 里加一条就多一种可查的外语。
/// 两边都只是一行，其他地方不用动。
enum DictionaryPresets {

    // MARK: - 母语（释义落在哪）

    struct Target {
        var code: String
        /// 用该语言自己写的名字，选择界面直接显示，不需要翻译
        var endonym: String
        /// Naver 韩语双语词典的 URL 形态
        var naver: NaverForm
        /// Papago / 谷歌翻译的目标语言代码
        var translate: String
        var googleSuffix: String
        var aiPrompt: String
    }

    /// Naver 的两种 URL 形态 —— 这一点很容易踩坑
    enum NaverForm {
        /// 英中日韩：独立子域名，还支持 range=word 只看单词
        case subdomain(String)
        /// 其余 60 多种：同一域名下的 <code>kodict 路径
        case path(String)
        /// Naver 没有这种语言 —— 主词典位置让给韩韩词典
        case none

        var url: String? {
            switch self {
            case .subdomain(let c): return "https://\(c).dict.naver.com/#/search?range=word&query={q}"
            case .path(let c): return "https://dict.naver.com/\(c)kodict/#/search?query={q}"
            case .none: return nil
            }
        }
    }

    static let targets: [Target] = [
        Target(code: "en", endonym: "English", naver: .subdomain("en"), translate: "en",
               googleSuffix: " meaning",
               aiPrompt: " — what does this word mean? Explain the meaning, part of speech, "
                   + "common usage, and give two example sentences."),
        Target(code: "zh", endonym: "中文", naver: .subdomain("zh"), translate: "zh-CN",
               googleSuffix: " 中文意思",
               aiPrompt: " 这个词是什么意思？请用中文说明词义、词性、常见搭配，并给两个例句。"),
        Target(code: "ja", endonym: "日本語", naver: .subdomain("ja"), translate: "ja",
               googleSuffix: " 意味",
               aiPrompt: " この単語の意味は？日本語で語義・品詞・よく使う言い回しと例文を2つ挙げてください。"),
        Target(code: "ko", endonym: "한국어", naver: .subdomain("ko"), translate: "ko",
               googleSuffix: " 뜻",
               aiPrompt: " 이 단어의 뜻은? 뜻과 품사, 자주 쓰는 표현, 예문 두 개를 한국어로 설명해 주세요."),
        Target(code: "ru", endonym: "Русский", naver: .path("ru"), translate: "ru",
               googleSuffix: " значение",
               aiPrompt: " — что означает это слово? Объясните значение, часть речи, "
                   + "типичное употребление и приведите два примера предложений."),
        Target(code: "vi", endonym: "Tiếng Việt", naver: .path("vi"), translate: "vi",
               googleSuffix: " nghĩa là gì",
               aiPrompt: " — từ này nghĩa là gì? Giải thích nghĩa, từ loại, "
                   + "cách dùng thường gặp và cho hai câu ví dụ."),
        Target(code: "it", endonym: "Italiano", naver: .path("it"), translate: "it",
               googleSuffix: " significato",
               aiPrompt: " — che cosa significa questa parola? Spiega il significato, "
                   + "la parte del discorso, l'uso comune e dai due frasi di esempio."),
    ]

    // MARK: - 要查的外语

    /// 可以勾选的来源语言。韩语是这个工具的主场，但其余的照样能加。
    static let selectableSources: [String] =
        ["ko", "en", "it", "ja", "zh", "ru", "vi", "fr", "de", "es"]

    /// 词典生成函数里 `t` 是局部变量（目标语言），会遮住取文案的全局 `t()`，
    /// 所以名字在这一层取好再传进去。
    static var offlineName: String { t("dict.offlineName") }

    /// App 里带的那份离线词库。没带就返回 nil —— 自己编译时可以不放，功能会安静地少一条。
    static var bundledDatabase: URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("krdict-kozh.sqlite"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func target(for code: String) -> Target {
        targets.first { $0.code == code } ?? targets[0]
    }

    /// 系统语言对应的母语，作为默认值和首次启动的预选项
    static var suggestedTarget: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        for t in targets where preferred.hasPrefix(t.code) { return t.code }
        return "en"
    }

    // MARK: - 生成词典集

    /// - Parameter userDictionaries: 用户自己加的词典。如果其中已经认领了某个来源语言，
    ///   就不再为那个语言生成 Glosbe —— 自己指定的站点优先，这正是「留给用户的那个口子」。
    static func dictionaries(target targetCode: String, sources: [String],
                             userDictionaries: [DictSite] = []) -> [DictSite] {
        let claimed = Set(userDictionaries.flatMap(\.languages))
        let t = target(for: targetCode)
        var sites: [DictSite] = []

        // ── 韩语：Naver 的双语词典，质量最好
        if sources.contains("ko") {
            if let url = t.naver.url {
                // 双向：사랑 → 释义，母语词 → 韩语说法，走同一个词典
                let both = targetCode == "ko" ? ["ko"] : ["ko", targetCode]
                sites.append(DictSite(id: "naver", name: "Naver KO-\(targetCode.uppercased())",
                                      languages: both, url: url, suffix: nil, external: nil))
            }
            sites.append(DictSite(id: "naverko", name: "국어사전",
                                  languages: t.naver.url == nil ? ["ko"] : [],
                                  url: "https://ko.dict.naver.com/#/search?query={q}",
                                  suffix: nil, external: nil))
            sites.append(DictSite(id: "papago", name: "Papago", languages: [],
                                  url: "https://papago.naver.com/?sk=ko&tk=\(t.translate)&st={q}",
                                  suffix: nil, external: nil))
        }

        // ── 打包在 App 里的离线词库。languages 留空 = 不抢自动路由，
        //    只在**断网**时顶上（见 DictRouter.index(for:in:online:)），或手动切。
        //    联网时 Naver 更全（叠了商业授权词典），没理由抢它的位置。
        if sources.contains("ko"), bundledDatabase != nil {
            sites.append(DictSite(id: "krdict", name: offlineName, languages: [],
                                  url: "file://BUNDLE/krdict-kozh.sqlite?q={q}",
                                  suffix: nil, external: nil))
        }

        // ── 其余外语：Glosbe。Naver 只做韩语对，这里补上任意 X→母语。
        //    但用户自己指定过站点的语言跳过 —— 他的选择优先于我们的默认值。
        for source in sources where source != "ko" && source != targetCode
                                 && !claimed.contains(source) {
            sites.append(DictSite(id: "glosbe-\(source)",
                                  name: "\(source.uppercased())→\(targetCode.uppercased())",
                                  languages: [source],
                                  url: "https://glosbe.com/\(source)/\(targetCode)/{q}",
                                  suffix: nil, external: nil))
        }

        // ── 通用兜底
        sites.append(DictSite(id: "gtrans", name: "Google Translate", languages: [],
                              url: "https://translate.google.com/?sl=auto&tl=\(t.translate)&text={q}&op=translate",
                              suffix: nil, external: nil))
        sites.append(DictSite(id: "google", name: "Google", languages: ["*"],
                              url: "https://www.google.com/search?q={q}",
                              suffix: t.googleSuffix, external: nil))
        // external：Google AI 模式依赖账号登录态，内嵌 WebView 是独立的未登录会话给不了
        sites.append(DictSite(id: "googleai", name: "AI", languages: [],
                              url: "https://www.google.com/search?q={q}&udm=50",
                              suffix: t.aiPrompt, external: true))
        return sites
    }

    /// 「常用词典」清单：把所有可选外语的预设都生成一遍去重，给添加界面当候选。
    ///
    /// 这些网址全都在本项目里实际跑通过 —— 让用户从验证过的里面挑，
    /// 好过让他自己去猜某个词典的查询链接长什么样。
    static func catalog(target targetCode: String) -> [DictSite] {
        var seen = Set<String>()
        return dictionaries(target: targetCode, sources: selectableSources).filter {
            seen.insert($0.id).inserted
        }
    }

    /// 预设占用的词典 id。换设置时只有这些被替换，其余视为用户自己加的，原样保留。
    static var allPresetDictionaryIDs: Set<String> {
        var ids: Set<String> = ["naver", "naverko", "papago", "gtrans", "google", "googleai",
                                "krdict"]
        for s in selectableSources { ids.insert("glosbe-\(s)") }
        return ids
    }

    // MARK: - 默认快捷键

    /// 前四条和词典无关，任何配置都一样。后面几条指向具体词典，
    /// **只为实际存在的词典生成** —— 不会出现按下去没反应的死键。
    static func defaultHotkeys(for dictionaries: [DictSite]) -> [HotKeyBinding] {
        var keys: [HotKeyBinding] = [
            .make(key: "9", control: true, option: true, source: .screenshot, dictionary: "auto"),
            .make(key: "0", control: true, option: true, source: .screenshot, action: .clipboard),
            .make(key: "8", control: true, option: true, source: .screenshot, action: .qrcode),
            .make(key: "7", control: true, option: true, source: .screenshot, action: .speak),
            .make(key: "D", option: true, command: true, source: .selection, dictionary: "auto"),
            .make(key: "F", option: true, command: true, source: .manual),
            // 原浏览器脚本用左Alt+Q，全局热键抢 ⌥Q 会挡住打特殊字符，加上 ⌘
            .make(key: "Q", option: true, command: true, source: .selection, action: .speak),
            // 原脚本用裸 ] [ 调速，全局热键得带修饰键
            .make(key: "]", option: true, command: true, source: .selection, action: .speakFaster),
            .make(key: "[", option: true, command: true, source: .selection, action: .speakSlower),
        ]
        // 助记字母取自词典的品牌名，和界面语言无关
        let mnemonics = [("naver", "N"), ("naverko", "K"), ("papago", "P"), ("gtrans", "G")]
        let available = Set(dictionaries.map(\.id))
        for (id, letter) in mnemonics where available.contains(id) {
            keys.append(.make(key: letter, option: true, command: true,
                              source: .selection, dictionary: id))
        }
        return keys
    }
}
