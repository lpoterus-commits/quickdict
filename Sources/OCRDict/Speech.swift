import AVFoundation
import Foundation
import NaturalLanguage

/// 朗读的总调度。从用户多年打磨的浏览器脚本（Tampermonkey「韩语朗读 v4.8」）移植，
/// 保留了那套为**学语言的人**调出来的处理管线：
///
/// - **清洗**：去掉符号，只留文字和停顿标点 —— 逗号句号不读出声，但换来自然的抑扬
/// - **诗歌友好**：空行分节、节间停顿；节内换行并成短停顿，不把一句诗读成硬邦邦两段
/// - **混排各读各的**：谚文段用韩语嗓音、汉字段用中文嗓音，逐节判定
/// - **缓存**：没选中就重读上一段 —— 反复听同一段是学外语的常态
///
/// 原脚本只活在浏览器标签页里；在这儿它挂在全局快捷键上，任何 App 里都能用，
/// 而且多了浏览器版做不到的一条：**截图 → OCR → 朗读**，扫描版教材也能听。
///
/// ## 3.1 起：声音可以换引擎出
///
/// 上面那套管线一个字没改，换掉的只是最后一步「把这段文字变成声音」。
/// 发声走 macOS 自带的合成器。**3.3 之前还有本机 Qwen 和微软在线两条路，
/// 连同整个 Python 边车一起移到了 Ausculta**（2026-08-25，用户拍板）——
/// 那边的「文字转语音」是独立成篇的合成工具，配着音频波形用；
/// 这里要的只是「按一下把选中的文字读出来」，系统嗓音够用且零依赖。
final class Speech: NSObject, @unchecked Sendable {
    static let shared = Speech()

    /// 唯一那条。类型写成协议而不是具体类，是为了测试能塞假的进来 ——
    /// 队列逻辑（顺序、失败换引擎、节尾停顿）没有声卡也该能验。
    private var system: SpeechEngine = SystemSpeechEngine()

    /// 上一次读的内容。快捷键按下时没有选中文字，就重读它。
    private var cached = ""
    /// 待读队列。**不一次性塞给引擎**，读完一段再喂下一段 ——
    /// 这样中途调语速，下一段就是新速度，不用停下来重放。
    private var queue: [SpeechChunk] = []
    private var currentRate = 1.0
    /// 从 `speak` 被调用到队列读空为止都是 true。
    /// 注意它**包含还在合成、没出声的那段时间** —— 对用户来说「按了朗读键」就算在读了，
    /// 这时再按一次该是「停下」，不该是「重读上一段」。
    private var running = false

    private override init() { super.init() }

    var isSpeaking: Bool { running }

    /// App 退出时叫一次。
    func shutdown() { stop() }

    /// **只给测试用**：把发声那条换成假的。
    ///
    /// 队列那段异步逻辑（一段读完接下一段、节尾停一拍）光靠听验不出顺序，
    /// 而真引擎依赖声卡，不适合进自动化测试。生产代码里没有任何地方调它。
    func injectEnginesForTesting(system: SpeechEngine) {
        self.system = system
    }

    // MARK: - 入口

    /// 全局快捷键的入口。一颗键管三件事，按当下状态分流：
    /// 有选中 → 读它（正在读就掐掉重来）；没选中 → 正在读就停，闲着就重读上一段。
    func handleHotkey(selection: String, config: AppConfig) {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            speak(text, config: config)
            return
        }
        if running {
            stop()
        } else if !cached.isEmpty {
            speak(cached, config: config)
        } else {
            HUD.shared.show(t("hud.nothingToSpeak"))
        }
    }

    func speak(_ text: String, config: AppConfig) {
        stop()
        let chunks = Self.plan(text, config: config)
        guard !chunks.isEmpty else {
            HUD.shared.show(t("hud.nothingToSpeak"))
            return
        }
        cached = text
        setRate(config.speechRate)
        queue = chunks
        running = true
        speakNext()
    }

    /// 语速改了从**下一段**起生效 —— 已经在嘴里的那句让它说完
    func setRate(_ multiplier: Double) {
        currentRate = min(max(multiplier, 0.5), 2.0)
    }

    func stop() {
        queue.removeAll()
        running = false
        system.stop()
    }

    // MARK: - 排活

    /// 把一段文字排成待读队列：清洗 → 分节 → 判语种 → 按引擎决定要不要切句。
    ///
    /// 抽成静态函数是为了能在没有引擎、没有 App 的情况下单测它 ——
    /// 排活的正确性和「谁来发声」无关。
    static func plan(_ text: String, config: AppConfig) -> [SpeechChunk] {
        var chunks: [SpeechChunk] = []
        for stanza in stanzas(of: text, skipNumbers: config.speechSkipsNumbers) {
            // 行内混排也各读各的：「사랑이라고 해요，意思是爱」拆成韩语段 + 中文段，
            // 各配各的嗓音。只按节切的话，整节用一个嗓音，混进来的那种语言会被啃坏。
            let runs = self.runs(of: stanza, config: config)
            for (index, run) in runs.enumerated() {
                // **一节一段，不再切句。** 神经引擎在的时候这里要切开，是因为它得把
                // 整段算完才出声，切碎能让第一声早点来；系统合成器是流式的，
                // 整段喂进去反而更连贯 —— 切开只会在每个接缝上留一道生硬的断。
                chunks.append(SpeechChunk(text: run.text, language: run.language,
                                          stanzaEnd: index == runs.count - 1))
            }
        }
        return chunks
    }


    /// 按句末标点切句。切不动的超长句（有些语言、有些 OCR 结果整段没有标点）
    /// 退而求其次在空格处硬切，免得一块吞进两百字、等出一分钟。
    static func sentences(of text: String, hardLimit: Int = 160) -> [String] {
        let enders: Set<Character> = ["。", ".", "？", "?", "！", "!", "…"]
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if enders.contains(ch) {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if piece.contains(where: { $0.isLetter || $0.isNumber }) { out.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if tail.contains(where: { $0.isLetter || $0.isNumber }) { out.append(tail) }

        return out.flatMap { $0.count > hardLimit ? split($0, at: hardLimit) : [$0] }
    }

    /// 没有标点可切时的下策：在空格处断开，凑够额度就收。
    /// 韩语、英语、意大利语都是分词书写的，这条走得通；中日文没有空格，
    /// 那就按字数硬断 —— 听感上会有个不自然的停顿，但总好过等半分钟不出声。
    private static func split(_ text: String, at limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 <= limit {
                current += " " + word
            } else {
                out.append(current)
                current = String(word)
            }
            while current.count > limit {          // 单个「词」就超长 = 无空格文本
                out.append(String(current.prefix(limit)))
                current = String(current.dropFirst(limit))
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - 播放

    private func speakNext() {
        guard running, !queue.isEmpty else {
            running = false
            return
        }
        let chunk = queue.removeFirst()
        // 系统合成器是流式的，喂进去就开始出声，没有「合成失败要换引擎补读」这回事 ——
        // 那套 fallback 是给神经引擎准备的，随它一起下了（2026-08-25）。
        system.play(chunk, rate: currentRate) { [weak self] _ in
            guard let self, self.running else { return }
            self.speakNext()
        }
    }


    // MARK: - 文本处理（对应原脚本的 sanitize + buildSegments）

    /// 空行分节；节内单个换行并成「 … 」—— 合成器会在省略号处自然停顿，
    /// 又不像分成两个 utterance 那样把一句诗读断。
    static func stanzas(of text: String, skipNumbers: Bool) -> [String] {
        let cleaned = sanitize(text, skipNumbers: skipNumbers)
        var stanzas: [String] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            let joined = current.joined(separator: " … ")
                .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            // 只剩标点的节（清洗后可能出现）没有可读内容，丢掉
            if joined.contains(where: { $0.isLetter || $0.isNumber }) { stanzas.append(joined) }
            current = []
        }
        for line in cleaned.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush() } else { current.append(trimmed) }
        }
        flush()
        return stanzas
    }

    /// 只留：各种文字、空白、能带来停顿的标点。数字按配置去留。
    ///
    /// 去符号不是洁癖 —— OCR 和网页选中常混进 `※`、`▶`、括注编号这类东西，
    /// 合成器会把它们一个个念出来，听感崩坏。
    static func sanitize(_ text: String, skipNumbers: Bool) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let c = Character(scalar)
            let keep: Bool
            let category = scalar.properties.generalCategory
            if c.isLetter { keep = true }
            // 组合附标不算 isLetter，但删掉它们等于毁字：泰语声调、阿拉伯语元音符、
            // 希伯来语标点符全在这一类（นี่ 会变成 นี ）
            else if category == .nonspacingMark || category == .spacingMark { keep = true }
            else if c.isNumber { keep = !skipNumbers }
            else if c == "\n" || c == " " { keep = true }
            else if "，,；;、。.？?！!…—".unicodeScalars.contains(scalar) { keep = true }
            else { keep = false }
            if keep { out.append(scalar) } else { out.append(" ") }
        }
        return String(out)
    }

    /// 把一节文本按**文字系统**切成语言段。
    ///
    /// 谚文、汉字、假名、西里尔字母都是确定性的，直接查码位；只有拉丁文分不出
    /// 英语还是意大利语，交给统计路由。空格、标点、数字归属前一段 ——
    /// 「사랑, 意思是爱」里的逗号跟着韩语段走，停顿发生在正确的位置。
    ///
    /// 汉字有个例外：这一节里**出现了假名**就按日语算 —— 日语句子几乎必带假名，
    /// 中文永远不带，这一条比任何统计都可靠。
    static func runs(of stanza: String, config: AppConfig) -> [(text: String, language: String)] {
        enum Script { case hangul, han, kana, latin, cyrillic, greek, hebrew, arabic, thai, devanagari }
        func script(_ scalar: Unicode.Scalar) -> Script? {
            switch scalar.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return .hangul
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return .han
            case 0x3040...0x30FF, 0x31F0...0x31FF: return .kana
            case 0x0400...0x04FF: return .cyrillic
            case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
            case 0x590...0x5FF: return .hebrew
            case 0x600...0x6FF, 0x750...0x77F: return .arabic
            case 0xE00...0xE7F: return .thai
            case 0x900...0x97F: return .devanagari
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
            default: return nil          // 空白、标点、数字：跟着前一段走
            }
        }

        var pieces: [(Script, String)] = []
        var pending = ""                  // 段首之前的中性字符，攒着给第一段
        for scalar in stanza.unicodeScalars {
            guard let sc = script(scalar) else {
                if pieces.isEmpty { pending.unicodeScalars.append(scalar) }
                else { pieces[pieces.count - 1].1.unicodeScalars.append(scalar) }
                continue
            }
            if let last = pieces.last, last.0 == sc {
                pieces[pieces.count - 1].1.unicodeScalars.append(scalar)
            } else {
                pieces.append((sc, pending))
                pieces[pieces.count - 1].1.unicodeScalars.append(scalar)
                pending = ""
            }
        }

        let hasKana = pieces.contains { $0.0 == .kana }
        var runs: [(text: String, language: String)] = []
        for (sc, text) in pieces {
            let language: String
            switch sc {
            case .hangul: language = "ko"
            case .kana: language = "ja"
            case .han: language = hasKana ? "ja" : "zh"
            case .cyrillic: language = "ru"
            case .greek: language = "el"
            case .hebrew: language = "he"
            case .arabic: language = "ar"
            case .thai: language = "th"
            case .devanagari: language = "hi"
            case .latin: language = latinLanguage(of: text, config: config)
            }
            // 相邻同语言的段并起来（汉字+假名交错的日语句子会切出一串碎段）
            if let last = runs.last, last.language == language {
                runs[runs.count - 1].text += text
            } else {
                runs.append((text, language))
            }
        }
        return runs.filter { $0.text.contains(where: { $0.isLetter }) }
    }

    /// 拉丁字母段判语言。
    ///
    /// **不借用查词那套候选表** —— 那边为了单词判得准，故意收窄到配置过词典的语言；
    /// 朗读拿到的是整句，统计识别可靠得多，也没理由要求「读法语得先配法语词典」。
    /// 放开识别，判不出来再落回配置的默认拉丁语。
    static func latinLanguage(of text: String, config: AppConfig) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= 0.4 else {
            return config.defaultLatinLanguage
        }
        return best.key.rawValue
    }

    /// 语言代码 → 这台机器上真实存在的嗓音。留在这里是为了兼容老调用点，
    /// 实现已经搬到 `SystemSpeechEngine`。
    static func voice(for code: String) -> AVSpeechSynthesisVoice? {
        SystemSpeechEngine.voice(for: code)
    }
}
