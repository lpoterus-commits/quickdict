import AVFoundation

/// 一段待读的文字：已经过清洗、分节、判语种，就等有人把它变成声音。
struct SpeechChunk {
    let text: String
    /// BCP-47 的语言部分（"ko"、"it"、"zh"…），由 `Speech.runs` 按文字系统判出
    let language: String
    /// 这一段是不是一节的最后一段 —— 是的话读完停一拍
    let stanzaEnd: Bool
}

/// 「把文字变成声音」这件事的接口。
///
/// 抽出来是因为现在有两条路：Qwen3-TTS（本机神经网络，好听）和系统合成器
/// （macOS 自带，秒回、覆盖四十种语言）。**清洗、分节、判语种那一整套管线两条路共用** ——
/// 那部分是这个工具多年打磨出来的东西，不该跟着引擎换来换去。
///
/// 引擎只管一件事：给我一段文字和一个语种，把它读出来，读完了叫我。
protocol SpeechEngine: AnyObject {
    /// 现在能不能用。Qwen 那条在边车没起来、模型没装完时是 false。
    var isReady: Bool { get }

    /// 认不认这门语言。Qwen3-TTS 只有十种；系统合成器装了嗓音就算认。
    func supports(_ language: String) -> Bool

    /// 读一段。读完（或读失败）调 completion，参数是「成功了吗」。
    /// **失败要如实回 false** —— 上层靠它决定要不要换一条引擎重试。
    func play(_ chunk: SpeechChunk, rate: Double, completion: @escaping (Bool) -> Void)

    /// 提前把下一段备好。默认什么都不做 —— 只有需要现算的引擎才用得上。
    func prefetch(_ chunk: SpeechChunk)

    /// 立刻闭嘴。已经在路上的 completion 不该再被当真。
    func stop()

    /// 刚播完那一段音频有多长。**只有拿得到音频数据的引擎答得上来** ——
    /// 系统合成器直接出声，音频不经过我们的手，所以它一直是 0。
    /// 合成过程页拿它对照「等了多久」：等待远大于音频长度就是这台机器跟不上。
    var lastAudioSeconds: TimeInterval { get }

    /// 从 `play` 被叫到**真的出声**之间隔了多久。
    ///
    /// **不能拿 completion 回来的时间去减** —— completion 是播完才回调的，
    /// 那个差值里含着整段音频的播放时长。实测过：一段 4.06 秒的音频「等待」记成 5.72 秒，
    /// 真实等待其实只有 1.66 秒；连带「等待 < 0.15 秒判为缓存命中」也跟着失效，
    /// 明明命中了缓存的块被标成现算的。
    var lastWaitSeconds: TimeInterval { get }
}

extension SpeechEngine {
    func prefetch(_ chunk: SpeechChunk) {}
    var lastAudioSeconds: TimeInterval { 0 }
    /// 系统合成器是同步开口的，等待按 0 算
    var lastWaitSeconds: TimeInterval { 0 }
}

// MARK: - 系统合成器

/// macOS 自带的 `AVSpeechSynthesizer`。
///
/// 3.0 之前这就是唯一的引擎，现在退到两个位置上：Qwen 覆盖不到的语言
/// （希腊语、阿拉伯语、泰语、印地语、越南语、希伯来语…），以及边车根本没装的机器。
/// 后一条很重要 —— 这个 App 是给全世界学韩语的人用的，不能假设每个人都愿意
/// 为了朗读装三个 G 的 Python。
/// 状态只在主线程碰（`Speech` 保证这一点），所以对合成器不是 Sendable 这件事
/// 按「已核对」处理 —— 和 3.0 之前 `Speech` 里那条判断是同一个理由。
final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate,
                                @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    /// 当前这一段读完时要叫的人。换段前必须清掉，不然 `stopSpeaking` 触发的
    /// `didFinish` 会把上一段的回调又叫一遍，队列就串了。
    private var pending: ((Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isReady: Bool { true }

    func supports(_ language: String) -> Bool { Self.voice(for: language) != nil }

    func play(_ chunk: SpeechChunk, rate: Double, completion: @escaping (Bool) -> Void) {
        guard let voice = Self.voice(for: chunk.language) else {
            completion(false)
            return
        }
        pending = completion
        // 系统合成器直接出声，音频不经过我们的手 —— 只能记「这段是它读的」，
        let utterance = AVSpeechUtterance(string: chunk.text)
        utterance.voice = voice
        utterance.rate = Float(min(max(rate, 0.5), 2.0)) * AVSpeechUtteranceDefaultSpeechRate
        // 节尾停一拍（原脚本对空行的处理）；节内换语言不停，读起来才连贯
        utterance.postUtteranceDelay = chunk.stanzaEnd ? 0.3 : 0
        synthesizer.speak(utterance)
    }

    func stop() {
        pending = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        let done = pending
        pending = nil
        done?(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        pending = nil            // 是我们自己掐的，别让上层接着读下一段
    }

    /// 语言代码 → 这台机器上真实存在的嗓音。
    ///
    /// 先按偏好区域找（zh 该配 zh-CN 而不是 yue-HK）；找不到就扫一遍已安装的嗓音
    /// 按前缀匹配 —— macOS 带着约四十种语言的嗓音，写死一张表反而会漏。
    static func voice(for code: String) -> AVSpeechSynthesisVoice? {
        let preferred = [
            "ko": "ko-KR", "zh": "zh-CN", "ja": "ja-JP", "en": "en-US",
            "ru": "ru-RU", "vi": "vi-VN", "it": "it-IT", "fr": "fr-FR",
            "de": "de-DE", "es": "es-ES", "el": "el-GR", "he": "he-IL",
            "ar": "ar-001", "th": "th-TH", "hi": "hi-IN", "pt": "pt-BR",
        ][code]
        if let preferred, let voice = AVSpeechSynthesisVoice(language: preferred) { return voice }
        if let voice = AVSpeechSynthesisVoice(language: code) { return voice }
        return AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language.hasPrefix(code + "-") }
    }
}
