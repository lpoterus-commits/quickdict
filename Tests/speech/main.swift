import AVFoundation
import AppKit
import Foundation

/// 朗读引擎的无界面测试。
///
/// 用整个模块（除了 `main.swift`）加这份自己的入口编出一个可执行文件跑 ——
/// 见 `Tests/speech/run.sh`。这样验的是**真代码**，不是复制一份逻辑出来验。
///
/// 三块：
///  1. 排活：清洗、分节、判语种、切块 —— 纯函数，固化住，改坏了立刻知道
///  2. 队列：一段接一段、失败换引擎补读、节尾停一拍 —— 塞假引擎进去，不出声
///  3. 音频：真的把边车合成的 WAV 解出来，验格式和时长 —— **不播**，测试不该吵
///
/// 第 3 块要边车在跑，没跑就跳过并说清楚（不算失败：这台机器可能没装模型）。

var passed = 0
var failed = 0

/// 泛型的：Int、String、Set 都能直接比
func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    if got == want {
        passed += 1
    } else {
        failed += 1
        print("  FAIL \(label)")
        print("    want: \(want)")
        print("    got:  \(got)")
    }
}

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("  FAIL \(label)\(detail().isEmpty ? "" : " — \(detail())")")
    }
}

let config = AppConfig.fallback

// ── 1. 排活 ────────────────────────────────────────────────────────────────

print("── 清洗与分节")

// 符号要被抹掉，但作为停顿的标点留着
check("去符号",
      Speech.sanitize("※사랑▶", skipNumbers: false).trimmingCharacters(in: .whitespaces),
      "사랑")
check("留停顿标点",
      Speech.sanitize("사랑, 意思是爱。", skipNumbers: false),
      "사랑, 意思是爱。")
// 组合附标不能被当成符号删掉，删了等于毁字
check("泰语声调符没被删",
      Speech.sanitize("นี่", skipNumbers: false).trimmingCharacters(in: .whitespaces),
      "นี่")
// 数字被抹成空格，句点作为停顿留着 —— 这正是「读课文时行号被静音、语调还在」的效果
check("跳过数字",
      Speech.sanitize("1. 사랑", skipNumbers: true).trimmingCharacters(in: .whitespaces),
      ". 사랑")
check("不跳过时数字还在",
      Speech.sanitize("1. 사랑", skipNumbers: false).contains("1"), true)

// 空行分节；节内换行并成省略号
let stanzas = Speech.stanzas(of: "첫째 줄\n둘째 줄\n\n다음 연", skipNumbers: false)
check("分节数", "\(stanzas.count)", "2")
check("节内换行并成省略号", stanzas.first ?? "", "첫째 줄 … 둘째 줄")

print("── 语种路由")

let mixed = Speech.runs(of: "사랑이라고 해요，意思是爱。", config: config)
check("韩中混排切成两段", "\(mixed.count)", "2")
check("第一段是韩语", mixed.first?.language ?? "", "ko")
check("第二段是中文", mixed.last?.language ?? "", "zh")
// 逗号跟着前一段走，停顿才落在对的位置
check("逗号归属前一段", mixed.first?.text.contains("，") ?? false)

// 有假名就整段按日语算 —— 中文永远不带假名，这条比统计可靠
let jp = Speech.runs(of: "図書館で本を借りました。", config: config)
check("含假名判日语", Set(jp.map(\.language)), Set(["ja"]))

let cyrillic = Speech.runs(of: "Привет", config: config)
check("西里尔判俄语", cyrillic.first?.language ?? "", "ru")
let thai = Speech.runs(of: "สวัสดี", config: config)
check("泰文判泰语", thai.first?.language ?? "", "th")

print("── 队列（假引擎，不出声）")

/// 记账用的假引擎。立刻「读完」，把读过什么记下来。
final class FakeEngine: SpeechEngine, @unchecked Sendable {
    let known: Set<String>
    private(set) var played: [String] = []
    init(known: Set<String>) { self.known = known }

    var isReady: Bool { true }
    func supports(_ language: String) -> Bool { known.contains(language) }

    func play(_ chunk: SpeechChunk, rate: Double, completion: @escaping (Bool) -> Void) {
        played.append("\(chunk.language):\(chunk.text)")
        // 异步回调，和真引擎一样 —— 同步回调会把递归 speakNext 的栈问题藏起来
        DispatchQueue.main.async { completion(true) }
    }

    func prefetch(_ chunk: SpeechChunk) {}
    func stop() {}
}

/// 跑一段，等队列读空（或超时），返回引擎读了什么。
func drive(_ text: String) -> FakeEngine {
    let engine = FakeEngine(known: ["ko", "zh", "ja", "en", "it", "ru", "th", "el"])
    Speech.shared.injectEnginesForTesting(system: engine)
    Speech.shared.speak(text, config: config)

    let deadline = Date().addingTimeInterval(5)
    while Speech.shared.isSpeaking, Date() < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }
    return engine
}

// 行内混排各读各的：一句话里的韩语段和中文段要分开，各配各的嗓音
var r = drive("사랑이라고 해요，意思是爱。")
check("混排切成两段", r.played.count, 2)
check("顺序没乱", r.played.first?.hasPrefix("ko:") ?? false)
check("第二段是中文", r.played.last?.hasPrefix("zh:") ?? false)

// 空行分节：两节各自成段，一句都不能丢
r = drive("사랑\n\nสวัสดีครับ")
check("两节各读一段", r.played.count, 2)
check("第二节是泰语", r.played.last?.hasPrefix("th:") ?? false)

// **一节一段，不再按句切。**
//
// 神经引擎在的时候这里要切碎，是为了让第一声早点来（它得整段算完才出声）。
// 系统合成器是流式的，喂进去就开始说 —— 切开只会在每个接缝上留一道生硬的断。
// 3.3 拆掉神经引擎时一并改的，写成测例免得以后又「顺手」把切句加回来。
let 长段 = String(repeating: "이것은 아주 긴 문장입니다. ", count: 12)
r = drive(长段)
check("整节一次读完，不切句", r.played.count == 1,
      "读了 \(r.played.count) 段 —— 切句回来了？系统合成器不需要它")

// 停止之后队列要空掉，不能自己接着往下读
Speech.shared.speak(长段, config: config)
Speech.shared.stop()
check("停止后不再是朗读中", Speech.shared.isSpeaking == false)

// 没有可读内容时不该崩，也不该假装在读
r = drive("※▶◆")
check("纯符号不产生任何朗读", r.played.isEmpty)

print("\n── 配置的存与读")

func decodeConfig(_ json: String) -> AppConfig? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(AppConfig.self, from: data)
}

// 8.2 缺字段的旧配置：落回默认，不是整份失效
let sparse = decodeConfig("""
{"windowZoom": 1.0, "speechRate": 1.2}
""")
check("缺字段的配置照样读得出来", sparse != nil)
check("写了的那项要保住", sparse?.speechRate ?? 0, 1.2)

// **「缺字段」和「类型写错」不是一回事，这里把区别钉住。**
// `decodeIfPresent` 只对「缺失 / null」返回 nil；值在但类型不对是会抛的，
// 于是整份配置退回默认（`ConfigStore.load` 的 catch）—— 用户别的设置一起没了。
// 这是现状，不是理想；写成测例是为了以后改它的时候知道自己在改什么。
let wrongType = decodeConfig("""
{"hotkeys": {}, "speechRate": 1.2}
""")
check("类型写错会整份解不出来（现状）", wrongType == nil,
      "居然解出来了 —— 行为变了，去看 ConfigStore.load 那条 catch 还在不在")


print("\n\(passed) 通过, \(failed) 失败")
exit(failed == 0 ? 0 : 1)
