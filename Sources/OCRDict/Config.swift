import Foundation

/// 一个词典站点。`url` 里的 {q} 会被替换成 URL 编码后的查询词。
struct DictSite: Codable {
    var id: String
    var name: String
    /// 命中的语言代码，"*" 表示兜底（所有未匹配的语言）
    var languages: [String]
    var url: String
    /// 编码前追加到查询词后面的内容，例如 " 中文意思"
    var suffix: String?
    /// true = 交给系统默认浏览器打开，不在内嵌 WebView 里加载。
    /// 用于那些依赖登录态的站点（内嵌 WebView 是独立的未登录会话）。
    var external: Bool?
    /// 笔记词典的资料清单（.md 文件或文件夹的路径）。
    ///
    /// 有值时以它为准，`url` 里的路径不再参与。这样一本词典可以由多份资料组成，
    /// 而且**增删在结果页面里就能做** —— 不必为每份资料单独配一条词典、多占一个标签。
    var notes: [String]?

    /// 是不是笔记词典
    var isNotes: Bool { !(notes ?? []).isEmpty || url.hasPrefix("file://") }
}

/// 取词的输入源
enum CaptureSource: String, Codable {
    case screenshot   // 框选截图 + OCR
    case selection    // 读当前选中的文字
    case manual       // 不取字，直接开窗口自己输入
}

/// 取到文字之后做什么
enum CaptureAction: String, Codable {
    case lookup       // 判语种 → 开词典
    case clipboard    // 智能拼行 → 只放剪贴板，不查词
    case qrcode       // 识别二维码/条码 → 打开链接
    case speak        // 朗读（选中的文字，或 OCR 出来的文字）
    // 显式小写 rawValue —— 绑定解析先把配置字符串 lowercased() 再比对，
    // 驼峰默认值永远对不上，会静默回落成 lookup
    case speakFaster = "speakfaster"  // 朗读加速一档（原脚本的 ] 键）
    case speakSlower = "speakslower"  // 朗读减速一档（原脚本的 [ 键）
}

/// 一条快捷键绑定。字段全是可选的，配置里漏写哪项都不会让整份配置失效。
struct HotKeyBinding: Codable {
    /// 人类可读的键名，如 "9" "N" "F5"。也可以直接写 keyCode。
    var key: String?
    var keyCode: UInt32?
    var control: Bool?
    var option: Bool?
    var shift: Bool?
    var command: Bool?
    /// "screenshot"（默认）或 "selection"
    var source: String?
    /// "lookup"（默认）/ "clipboard" / "qrcode"
    var action: String?
    /// 仅 lookup 用："auto"（默认，按语种自动选）或某个词典的 id
    var dictionary: String?

    var resolvedKeyCode: UInt32? { keyCode ?? KeyCodeNames.code(for: key ?? "") }

    var captureSource: CaptureSource {
        CaptureSource(rawValue: (source ?? "screenshot").lowercased()) ?? .screenshot
    }

    var captureAction: CaptureAction {
        CaptureAction(rawValue: (action ?? "lookup").lowercased()) ?? .lookup
    }

    /// nil 表示走自动路由
    var targetDictionary: String? {
        guard let dictionary, dictionary.lowercased() != "auto", !dictionary.isEmpty else { return nil }
        return dictionary
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if control == true { m |= UInt32(controlKeyMask) }
        if option == true { m |= UInt32(optionKeyMask) }
        if shift == true { m |= UInt32(shiftKeyMask) }
        if command == true { m |= UInt32(commandKeyMask) }
        return m
    }

    var displayString: String {
        var s = ""
        if control == true { s += "⌃" }
        if option == true { s += "⌥" }
        if shift == true { s += "⇧" }
        if command == true { s += "⌘" }
        return s + (key?.uppercased() ?? resolvedKeyCode.map { KeyCodeNames.name(for: $0) } ?? "?")
    }

    static func make(key: String, control: Bool = false, option: Bool = false,
                     shift: Bool = false, command: Bool = false,
                     source: CaptureSource, action: CaptureAction = .lookup,
                     dictionary: String? = nil) -> HotKeyBinding {
        HotKeyBinding(key: key, keyCode: nil, control: control, option: option,
                      shift: shift, command: command,
                      source: source.rawValue, action: action.rawValue, dictionary: dictionary)
    }
}

// Carbon 的修饰键常量，抄成字面量免得为了四个数去 import Carbon
private let controlKeyMask = 4096
private let optionKeyMask = 2048
private let shiftKeyMask = 512
private let commandKeyMask = 256

struct AppConfig: Codable {
    var hotkeys: [HotKeyBinding]
    /// 让 Vision 自动挑选识别模型。必须开着，否则拉丁语与 CJK 混排时识别不出 CJK。
    /// 关掉后会退化成逐语言尝试 ocrLanguages，慢且不一定更准。
    var autoDetectLanguage: Bool
    /// 给 Vision 的语言提示，同时也是自动识别失败时逐个重试的候选列表
    var ocrLanguages: [String]
    /// 拉丁字母无法可靠判定时使用的语言
    var defaultLatinLanguage: String
    /// 低于此置信度就认为拉丁语系判定不可靠
    var latinConfidenceThreshold: Double
    /// true: 连续空白折叠成一个空格（词组安全）；false: 全部删除
    var collapseWhitespaceToSpace: Bool
    /// true: 所有词典都直接丢给默认浏览器，不弹内置窗口
    var openInBrowser: Bool
    /// 结果窗口是否默认置顶。false 时切到别的 App 会被正常盖住；
    /// 需要一边看词典一边打字时，用工具栏上的图钉按钮临时置顶。
    var alwaysOnTop: Bool
    /// 退出时清空内嵌 WebView 的 Cookie / localStorage / 缓存。
    /// 本 App 自己不记历史，但词典网站会往 localStorage 里塞「最近搜索」。
    var clearDataOnQuit: Bool
    /// 二维码里的链接打开前先弹窗确认。二维码是不可读的，扫到什么网址肉眼看不出来，
    /// 想稳一点就把这个打开。
    var qrConfirmBeforeOpen: Bool
    /// 补充的韩语助词/词尾。断词还原判定「行首是不是悬空的黏着语素」时会用上。
    /// 内置表是我按语法整理的，母语者发现漏了什么，往这里加就行 —— 不用改代码、不用重新编译。
    var koreanExtraParticles: [String]
    /// 补充的「能独立成词的单音节」。内置表误判把某个词粘到上一行时，往这里加。
    var koreanExtraStandalone: [String]
    /// 除韩语外还要查哪些外语。每加一种就多一个 X→母语 的词典。
    /// 韩语固定在内（这是工具的主场），列表里写的是额外的。
    var sourceLanguages: [String]
    /// 查到哪种语言。首次启动时按系统语言自动判定，之后可在菜单里换。
    /// 换这个值会整套替换 dictionaries，所以手改过词典的人不要动它。
    var dictionaryLanguage: String
    var windowWidth: Double
    var windowHeight: Double
    /// 结果窗口的字号比例。⌘+ / ⌘- 改，⌘0 回到 1.0
    var windowZoom: Double
    /// 朗读语速，1.0 = 正常，范围 0.5–2.0
    var speechRate: Double
    /// 朗读时跳过数字。读诗歌、课文时行号页码是噪音，开了它们就被静音
    var speechSkipsNumbers: Bool
    var dictionaries: [DictSite]

    static let fallback = AppConfig(
        // 快捷键也随词典集走：指向具体词典的那几个键，只为实际存在的词典生成
        hotkeys: DictionaryPresets.defaultHotkeys(
            for: DictionaryPresets.dictionaries(target: DictionaryPresets.suggestedTarget,
                                                sources: ["ko"])),
        autoDetectLanguage: true,
        ocrLanguages: ["en-US", "ko-KR", "it-IT", "zh-Hans", "ja-JP"],
        defaultLatinLanguage: "en",
        latinConfidenceThreshold: 0.65,
        collapseWhitespaceToSpace: true,
        openInBrowser: false,
        alwaysOnTop: false,
        clearDataOnQuit: true,
        qrConfirmBeforeOpen: false,
        koreanExtraParticles: [],
        koreanExtraStandalone: [],
        sourceLanguages: ["ko"],
        dictionaryLanguage: DictionaryPresets.suggestedTarget,
        windowWidth: 900,
        windowHeight: 680,
        windowZoom: 1.0,
        speechRate: 1.0,
        speechSkipsNumbers: false,
        // 默认词典按系统语言自动定 —— 装上就能用，不需要先去改配置
        dictionaries: DictionaryPresets.dictionaries(target: DictionaryPresets.suggestedTarget,
                                                     sources: ["ko"])
    )
}

// 缺字段时回落到默认值，这样手改配置漏写一项也不会整份失效。
extension AppConfig {
    /// v1 只有单个 hotkey 字段，读到旧配置时迁移到 hotkeys 数组
    private enum LegacyKeys: String, CodingKey { case hotkey }

    enum CodingKeys: String, CodingKey {
        case hotkeys
        case autoDetectLanguage, ocrLanguages, defaultLatinLanguage, latinConfidenceThreshold
        case collapseWhitespaceToSpace, openInBrowser, alwaysOnTop, clearDataOnQuit
        case qrConfirmBeforeOpen, koreanExtraParticles, koreanExtraStandalone
        case sourceLanguages, dictionaryLanguage, windowWidth, windowHeight, windowZoom, speechRate, speechSkipsNumbers, dictionaries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.fallback
        if let list = try c.decodeIfPresent([HotKeyBinding].self, forKey: .hotkeys), !list.isEmpty {
            hotkeys = list
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(HotKeyBinding.self, forKey: .hotkey), legacy.resolvedKeyCode != nil {
            // 旧版只有一个截图快捷键，迁移过来并补上新增的划词绑定
            var migrated = legacy
            migrated.source = CaptureSource.screenshot.rawValue
            migrated.dictionary = "auto"
            hotkeys = [migrated] + d.hotkeys.filter { $0.captureSource == .selection }
        } else {
            hotkeys = d.hotkeys
        }
        autoDetectLanguage = try c.decodeIfPresent(Bool.self, forKey: .autoDetectLanguage) ?? d.autoDetectLanguage
        ocrLanguages = try c.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? d.ocrLanguages
        defaultLatinLanguage = try c.decodeIfPresent(String.self, forKey: .defaultLatinLanguage) ?? d.defaultLatinLanguage
        latinConfidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .latinConfidenceThreshold) ?? d.latinConfidenceThreshold
        collapseWhitespaceToSpace = try c.decodeIfPresent(Bool.self, forKey: .collapseWhitespaceToSpace) ?? d.collapseWhitespaceToSpace
        openInBrowser = try c.decodeIfPresent(Bool.self, forKey: .openInBrowser) ?? d.openInBrowser
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? d.alwaysOnTop
        clearDataOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearDataOnQuit) ?? d.clearDataOnQuit
        qrConfirmBeforeOpen = try c.decodeIfPresent(Bool.self, forKey: .qrConfirmBeforeOpen) ?? d.qrConfirmBeforeOpen
        koreanExtraParticles = try c.decodeIfPresent([String].self, forKey: .koreanExtraParticles) ?? []
        koreanExtraStandalone = try c.decodeIfPresent([String].self, forKey: .koreanExtraStandalone) ?? []
        let sources = try c.decodeIfPresent([String].self, forKey: .sourceLanguages) ?? d.sourceLanguages
        // 韩语是这个工具的主场，不允许被配没了
        sourceLanguages = sources.contains("ko") ? sources : ["ko"] + sources
        dictionaryLanguage = try c.decodeIfPresent(String.self, forKey: .dictionaryLanguage) ?? d.dictionaryLanguage
        windowWidth = try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? d.windowWidth
        windowHeight = try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? d.windowHeight
        windowZoom = try c.decodeIfPresent(Double.self, forKey: .windowZoom) ?? d.windowZoom
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? d.speechRate
        speechSkipsNumbers = try c.decodeIfPresent(Bool.self, forKey: .speechSkipsNumbers) ?? d.speechSkipsNumbers
        let dicts = try c.decodeIfPresent([DictSite].self, forKey: .dictionaries) ?? d.dictionaries
        dictionaries = dicts.isEmpty ? d.dictionaries : dicts
    }
}

enum ConfigStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // 按 bundle ID 分目录：冻结的 2.0 和开发中的 3.x 各用各的配置，互不干扰
        let name = Bundle.main.bundleIdentifier ?? "OCRDict"
        return base.appendingPathComponent(name, isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            let cfg = AppConfig.fallback
            save(cfg)
            return cfg
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            NSLog("[OCRDict] 配置解析失败，改用默认配置: \(error)")
            return .fallback
        }
    }

    @discardableResult
    static func save(_ config: AppConfig) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(config).write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("[OCRDict] 配置写入失败: \(error)")
            return false
        }
    }
}

enum KeyCodeNames {
    private static let table: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        36: "\u{21A9}", 48: "\u{21E5}", 49: "\u{2423}", 53: "esc", 33: "[", 30: "]",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let aliases: [String: UInt32] = [
        "SPACE": 49, "空格": 49, "\u{2423}": 49, "RETURN": 36, "ENTER": 36, "回车": 36, "\u{21A9}": 36,
        "TAB": 48, "ESC": 53, "ESCAPE": 53,
    ]

    static func name(for code: UInt32) -> String { table[code] ?? "#\(code)" }

    /// 反向查找：把配置里写的 "N" / "9" / "F5" / "space" 变成虚拟键码
    static func code(for name: String) -> UInt32? {
        let key = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return nil }
        if let code = aliases[key] { return code }
        return table.first { $0.value.uppercased() == key }?.key
    }
}
