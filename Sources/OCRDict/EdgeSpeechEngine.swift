import AVFoundation
import CryptoKit
import Foundation

/// 微软 Edge 的在线朗读服务。
///
/// 神经网络音色，比系统自带的好听不少 —— 代价是**要联网**，而且用的是 Edge
/// 「大声朗读」自己那条接口，不是有文档的公开 API。所以这里的设计前提是
/// **它随时可能不通**：合成失败一律如实回 `false`，由上层换回系统嗓音继续读，
/// 而不是让用户按了键没声音。
///
/// ## 为什么不直接调 Azure
///
/// Azure 的 TTS 要密钥、要计费账号。这个 App 是给学韩语的人用的，不该要求
/// 每个人先去开一个云服务账号。Edge 这条不用密钥，代价是接口没有承诺。
///
/// ## 握手要算一个时间戳令牌
///
/// 服务端要 `Sec-MS-GEC`：把 Windows 文件时间（1601 纪元、100 纳秒为单位）
/// **向下取整到 5 分钟**，接上固定令牌串做 SHA-256，大写十六进制。
/// 取整到 5 分钟这一步是关键 —— 客户端和服务端各自算各自的，靠对齐时间窗口对上。
final class EdgeSpeechEngine: NSObject, SpeechEngine, AVAudioPlayerDelegate, @unchecked Sendable {

    private static let clientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromium = "143.0.3650.75"
    private static let base = "speech.platform.bing.com/consumer/speech/synthesize/readaloud"

    /// 每种语言用哪个嗓音。挑的都是各语言的女声默认款，和系统嗓音的取向一致。
    /// 表里没有的语言 `supports` 返回 false，那一段直接交给系统嗓音。
    static let voices: [String: String] = [
        "ko": "ko-KR-SunHiNeural",   "zh": "zh-CN-XiaoxiaoNeural", "ja": "ja-JP-NanamiNeural",
        "en": "en-US-AriaNeural",    "it": "it-IT-ElsaNeural",     "ru": "ru-RU-SvetlanaNeural",
        "vi": "vi-VN-HoaiMyNeural",  "fr": "fr-FR-DeniseNeural",   "de": "de-DE-KatjaNeural",
        "es": "es-ES-ElviraNeural",  "pt": "pt-BR-FranciscaNeural", "th": "th-TH-PremwadeeNeural",
        "hi": "hi-IN-SwaraNeural",   "ar": "ar-SA-ZariyahNeural",  "he": "he-IL-HilaNeural",
        "el": "el-GR-AthinaNeural",
    ]

    private var player: AVAudioPlayer?
    private var pending: ((Bool) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var stanzaPause = false
    private(set) var lastAudioSeconds: TimeInterval = 0
    private(set) var lastWaitSeconds: TimeInterval = 0

    var isReady: Bool { Reachability.isOnline }

    func supports(_ language: String) -> Bool { Self.voices[language] != nil }

    // MARK: - 发声

    func play(_ chunk: SpeechChunk, rate: Double, completion: @escaping (Bool) -> Void) {
        guard let voice = Self.voices[chunk.language] else { completion(false); return }
        let started = Date()

        func start(_ mp3: Data) {
            DispatchQueue.main.async {
                self.lastWaitSeconds = Date().timeIntervalSince(started)
                guard self.begin(mp3, rate: rate, stanzaEnd: chunk.stanzaEnd, completion: completion)
                else { completion(false); return }
            }
        }

        // 读过的段落直接从盘上取。反复听同一段是学外语的常态，
        // 没有理由为同一句话反复走网络。
        if let cached = Self.cache.read(voice: voice, text: chunk.text) {
            start(cached)
            return
        }
        synthesize(text: chunk.text, voice: voice) { [weak self] data in
            guard let self, let data, !data.isEmpty else { completion(false); return }
            Self.cache.write(voice: voice, text: chunk.text, data: data)
            _ = self
            start(data)
        }
    }

    /// 起播。返回 false 表示这段音频压根解不开 —— 上层该换引擎。
    private func begin(_ mp3: Data, rate: Double, stanzaEnd: Bool,
                       completion: @escaping (Bool) -> Void) -> Bool {
        guard let made = try? AVAudioPlayer(data: mp3) else { return false }
        made.delegate = self
        made.enableRate = true                     // 变速保持音高，不会变成怪声
        made.rate = Float(min(max(rate, 0.5), 2.0))
        guard made.prepareToPlay(), made.play() else { return false }
        player = made
        pending = completion
        stanzaPause = stanzaEnd
        lastAudioSeconds = made.duration
        return true
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let done = pending
        pending = nil
        // 节尾停一拍，和系统引擎的 postUtteranceDelay 对齐
        DispatchQueue.main.asyncAfter(deadline: .now() + (stanzaPause ? 0.3 : 0)) {
            done?(flag)
        }
    }

    func stop() {
        pending = nil                  // 掐掉的段落不该再叫回调，否则队列会串
        player?.stop()
        player = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - 合成

    private func synthesize(text: String, voice: String,
                            completion: @escaping (Data?) -> Void) {
        var seen = false
        func finish(_ data: Data?) {
            guard !seen else { return }        // 超时和正常结束可能撞在一起
            seen = true
            completion(data)
        }

        guard let url = Self.endpoint() else { finish(nil); return }
        var request = URLRequest(url: url)
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                         + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()

        socket.send(.string(Self.configMessage())) { _ in }
        socket.send(.string(Self.ssmlMessage(text: text, voice: voice))) { error in
            if error != nil { finish(nil) }
        }

        var audio = Data()
        func receive() {
            socket.receive { result in
                switch result {
                case .failure:
                    finish(audio.isEmpty ? nil : audio)
                case .success(let message):
                    switch message {
                    case .data(let frame):
                        // 二进制帧：前两字节是头部长度（大端），其后是头部，再其后才是音频
                        guard frame.count > 2 else { break }
                        let headerLength = Int(frame[0]) << 8 | Int(frame[1])
                        let start = 2 + headerLength
                        if frame.count > start { audio.append(frame.subdata(in: start..<frame.count)) }
                    case .string(let text):
                        if text.contains("Path:turn.end") {
                            socket.cancel(with: .normalClosure, reason: nil)
                            finish(audio.isEmpty ? nil : audio)
                            return
                        }
                    @unknown default: break
                    }
                    receive()
                }
            }
        }
        receive()

        // 网络慢就别等了 —— 按下朗读键却卡住几秒，比换个嗓音难受得多
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            if !seen { socket.cancel(with: .goingAway, reason: nil) }
            finish(audio.isEmpty ? nil : audio)
        }
    }

    // MARK: - 协议细节

    /// `Sec-MS-GEC`：Windows 文件时间取整到 5 分钟 + 固定令牌，SHA-256 大写十六进制
    static func securityToken(now: Date = Date()) -> String {
        let winEpochOffset = 11_644_473_600.0
        var seconds = (now.timeIntervalSince1970 + winEpochOffset).rounded(.down)
        seconds -= seconds.truncatingRemainder(dividingBy: 300)
        let ticks = UInt64(seconds) * 10_000_000
        let digest = SHA256.hash(data: Data("\(ticks)\(clientToken)".utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func endpoint(now: Date = Date()) -> URL? {
        URL(string: "wss://\(base)/edge/v1?TrustedClientToken=\(clientToken)"
            + "&Sec-MS-GEC=\(securityToken(now: now))&Sec-MS-GEC-Version=1-\(chromium)")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    /// 帧的格式是「`键:值\r\n` 若干行 + 空行 + 正文」，和 HTTP 头像但不是 HTTP
    private static func configMessage() -> String {
        "X-Timestamp:\(timestamp())\r\n"
        + "Content-Type:application/json; charset=utf-8\r\n"
        + "Path:speech.config\r\n\r\n"
        + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"#
        + #""sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"#
        + #""outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"# + "\r\n"
    }

    private static func ssmlMessage(text: String, voice: String) -> String {
        let language = voice.split(separator: "-").prefix(2).joined(separator: "-")
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
            + "xml:lang='\(language)'><voice name='\(voice)'>\(escape(text))</voice></speak>"
        return "X-RequestId:\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestamp())Z\r\n"      // 末尾这个 Z 是 Edge 自己的怪癖，去掉会被拒
            + "Path:ssml\r\n\r\n\(ssml)"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - 缓存

    /// 读过的段落存在盘上。反复听同一句是学外语的常态，没必要为同一句话反复走网络。
    /// 键里不含语速 —— 变速是播放时做的，同一段音频能给所有语速用。
    struct Cache {
        var directory: URL {
            let dir = ConfigStore.directory.appendingPathComponent("speech-cache", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        private func file(voice: String, text: String) -> URL {
            let digest = SHA256.hash(data: Data("\(voice)\u{1}\(text)".utf8))
            return directory.appendingPathComponent(
                digest.map { String(format: "%02x", $0) }.joined() + ".mp3")
        }

        func read(voice: String, text: String) -> Data? {
            try? Data(contentsOf: file(voice: voice, text: text))
        }

        func write(voice: String, text: String, data: Data) {
            try? data.write(to: file(voice: voice, text: text), options: .atomic)
        }

        /// 缓存是派生物，清掉还能再下。超过上限就整个倒掉 ——
        /// 按最近使用逐个淘汰要记访问时间，为几十兆的音频不值得。
        func prune(limit: Int64 = 60 * 1024 * 1024) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let total = files.reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            guard total > limit else { return }
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    static let cache = Cache()
}
