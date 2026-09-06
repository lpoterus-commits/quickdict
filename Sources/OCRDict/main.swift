import AppKit
import AVFoundation
import ServiceManagement
import ImageIO

// 调试入口：不启动 GUI，直接对一张图跑完 OCR → 清洗 → 语种判定 → 出 URL。
// 用法: 快捷查词助手.app/Contents/MacOS/OCRDict --ocr <图片路径>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--ocr" {
    let path = CommandLine.arguments[2]
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        FileHandle.standardError.write("无法读取图片: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    let config = ConfigStore.load()
    let raw = OCR.recognize(image: image, languages: config.ocrLanguages,
                            autoDetect: config.autoDetectLanguage)
    let text = TextClean.normalize(raw, collapseToSpace: config.collapseWhitespaceToSpace)
    guard !text.isEmpty else {
        print("未识别到文字")
        exit(2)
    }
    let route = LanguageRouter.route(text, config: config)
    let index = DictRouter.index(for: route.language, in: config.dictionaries)
    let site = config.dictionaries[index]
    print("识别: \(text)")
    print("语种: \(route.language) (\(route.displayName)) 置信度 \(String(format: "%.2f", route.confidence))\(route.ambiguous ? " [不可靠]" : "")")
    print("词典: \(site.name)")
    print("链接: \(DictRouter.url(site: site, query: text)?.absoluteString ?? "-")")
    exit(0)
}

// 调试入口：--qr <图片> 打印识别到的二维码/条码
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--qr" {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        FileHandle.standardError.write("无法读取图片\n".data(using: .utf8)!)
        exit(1)
    }
    let hits = QRCode.detect(in: image)
    guard !hits.isEmpty else {
        print("没有识别到二维码/条形码")
        exit(2)
    }
    for hit in hits {
        print("[\(hit.symbology)] \(hit.payload)")
        print("  可打开链接: \(hit.url?.absoluteString ?? "否（非 http/https，会改为复制）")")
    }
    exit(0)
}

// 调试入口：--join <图片> 打印智能拼行的结果，用来验证断词还原
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--join" {
    let path = CommandLine.arguments[2]
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        FileHandle.standardError.write("无法读取图片: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    let config = ConfigStore.load()
    let lines = OCR.recognizeLines(image: image, languages: config.ocrLanguages,
                                   autoDetect: config.autoDetectLanguage)
    if CommandLine.arguments.contains("--verbose") {
        for line in lines {
            FileHandle.standardError.write(
                String(format: "  maxX=%.3f w=%.3f  %@\n", line.box.maxX, line.box.width, line.text)
                    .data(using: .utf8)!)
        }
    }
    let joined = LineJoiner.joined(lines)
    print(joined.text)
    if !joined.ambiguous.isEmpty {
        FileHandle.standardError.write(
            "⚠️ 合并了但拆开也讲得通: \(joined.ambiguous.joined(separator: "、"))\n".data(using: .utf8)!)
    }
    exit(0)
}

// 调试入口：--notes <file.md> 把笔记解析结果打成 TSV。
// 测试脚本靠它盯住整条转换管线：标题识别、目录跳过、搜索键生成、活用推导。
// 键按字典序打印 —— 生成时按长度排序，等长键的顺序没有保证，直接比会闪失败。
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--notes" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    for entry in Notes.parse(url) {
        let keys = entry.keys.sorted().joined(separator: "|")
        print("\(entry.num)\t\(entry.form)\t\(entry.cat)\t\(entry.gloss)\t\(keys)")
    }
    exit(0)
}

// 调试入口：--route <语言> <on|off> 打印这个语言在联网/断网下会落到哪本词典
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--route" {
    let config = ConfigStore.load()
    let index = DictRouter.index(for: CommandLine.arguments[2], in: config.dictionaries,
                                 online: CommandLine.arguments[3] == "on")
    print(config.dictionaries[index].name)
    exit(0)
}

// 调试入口：--combos 列出编辑器允许的每个「来源 + 动作」组合，
// 用来和 AppDelegate.dispatch 的实际分支对账
if CommandLine.arguments.contains("--combos") {
    for source in HotkeysPane.sources {
        let actions = HotkeysPane.actions(for: source)
        print("\(source.rawValue): " + (actions.isEmpty ? "-" : actions.map(\.rawValue).joined(separator: ",")))
    }
    exit(0)
}

// 调试入口：--clear-kinds 检查两类数据的划分：登录只含 Cookie，
// 浏览数据不含 Cookie，两者不相交
if CommandLine.arguments.contains("--clear-kinds") {
    let logins = WebData.Kind.logins.types
    let browsing = WebData.Kind.browsing.types
    print("logins=\(logins.count) browsing\(browsing.count > 1 ? ">1" : "<=1") "
        + "disjoint=\(logins.isDisjoint(with: browsing) ? "yes" : "no")")
    exit(0)
}

// 调试入口：--clear browsing|logins|all 只清指定的一类，用来验证两者确实互不牵连
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--clear" {
    let kind: WebData.Kind = CommandLine.arguments[2] == "logins" ? .logins
        : (CommandLine.arguments[2] == "browsing" ? .browsing : .all)
    WebData.clearBlocking(kind)
    print("已清除：\(CommandLine.arguments[2])")
    exit(0)
}

// 调试入口：--webdata 列出哪些站点存了东西、存的是不是登录凭据
if CommandLine.arguments.contains("--webdata") {
    var done = false
    WebData.records { list in
        print("落盘 \(WebData.formatted(WebData.diskUsage()))，\(list.count) 个站点")
        for entry in list {
            print("  \(entry.hasLogin ? "登录" : "  · ")  \(entry.site)")
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(5)
    while !done, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// 调试入口：--login on|off 直接试注册/注销登录项，把系统给的错误原样打出来
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--login" {
    do {
        if CommandLine.arguments[2] == "on" {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        print("成功，当前状态码 \(SMAppService.mainApp.status.rawValue)")
    } catch {
        print("失败：\(error)")
    }
    print("Bundle: \(Bundle.main.bundlePath)")
    exit(0)
}

// 调试入口：--tts-edge-stop 播一段，中途叫停，看声音是不是真的断了
if CommandLine.arguments.contains("--tts-edge-stop") {
    let engine = EdgeSpeechEngine()
    let chunk = SpeechChunk(text: "오늘은 날씨가 참 좋습니다. 도서관에 가서 책을 읽을 생각입니다.",
                            language: "ko", stanzaEnd: false)
    var started = false
    engine.play(chunk, rate: 1.0) { _ in }
    let deadline = Date().addingTimeInterval(10)
    while !started, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        started = engine.isPlaying
    }
    guard started else { print("没能开始播放，无法验证"); exit(1) }
    print("停止前 isPlaying=\(engine.isPlaying)")
    engine.stop()
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    print("停止后 isPlaying=\(engine.isPlaying)")
    exit(0)
}

// 调试入口：--speak-stop-check 验「停止」有没有到达每一条引擎。
// 塞两个只会数数的假引擎进去，喂一段，然后停，看两边各被停了几次。
if CommandLine.arguments.contains("--speak-stop-check") {
    final class CountingEngine: SpeechEngine {
        var stopped = 0
        var isReady = true
        func supports(_ language: String) -> Bool { true }
        func play(_ chunk: SpeechChunk, rate: Double, completion: @escaping (Bool) -> Void) {}
        func stop() { stopped += 1 }
    }
    let fakeSystem = CountingEngine(), fakeRemote = CountingEngine()
    Speech.shared.injectEnginesForTesting(system: fakeSystem, remote: fakeRemote)
    var config = ConfigStore.load()
    config.speechEngine = "edge"
    Speech.shared.speak("사랑해요", config: config)
    fakeSystem.stopped = 0; fakeRemote.stopped = 0    // speak 自己会先停一次，不算
    Speech.shared.stop()
    print("system=\(fakeSystem.stopped) remote=\(fakeRemote.stopped)")
    exit(0)
}

// 调试入口：--speak-decide <选中的文字> <0|1 正在读> <上一段> 打印按键该做什么
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--speak-decide" {
    switch Speech.outcome(selection: CommandLine.arguments[2],
                          running: CommandLine.arguments[3] == "1",
                          cached: CommandLine.arguments[4]) {
    case .stop: print("stop")
    case .speak(let text): print("speak:\(text)")
    case .nothing: print("nothing")
    }
    exit(0)
}

// 调试入口：--tts-token 打印握手用的时间戳令牌，好和独立算法对账
if CommandLine.arguments.contains("--tts-token") {
    print(EdgeSpeechEngine.securityToken())
    exit(0)
}

// 调试入口：--tts-edge <语种> <文本> 只跑一次在线合成，报字节数和耗时
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--tts-edge" {
    let engine = EdgeSpeechEngine()
    let chunk = SpeechChunk(text: CommandLine.arguments[3],
                            language: CommandLine.arguments[2], stanzaEnd: false)
    guard engine.supports(chunk.language) else { print("这门语言微软没有"); exit(1) }
    let started = Date()
    var done = false
    engine.play(chunk, rate: 1.0) { spoke in
        print(spoke
              ? "成功：音频 \(String(format: "%.2f", engine.lastAudioSeconds)) 秒，"
                + "等待 \(String(format: "%.2f", engine.lastWaitSeconds)) 秒"
              : "失败，会回落系统嗓音")
        done = true
    }
    let deadline = started.addingTimeInterval(20)
    while !done, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// 调试入口：--help-html 打印使用说明。它是按配置生成的用户文档，
// 出错的方式和界面一样（漏译、印出按不出来的键），所以也要能自动检查
if CommandLine.arguments.contains("--help-html") {
    print(HelpDocument.html(config: ConfigStore.load()))
    exit(0)
}

// 调试入口：--home-html 打印主页内容，验证它确实跟着配置走
if CommandLine.arguments.contains("--home-html") {
    let config = ConfigStore.load()
    print(HomePage.html(config: config, status: .current(config: config)))
    exit(0)
}

// 调试入口：--perm-html 打印权限页。和主页一样，它也是按实际状态生成的用户文档，
// 会以同样的方式坏掉（漏译、状态判反），所以也要能自动检查
if CommandLine.arguments.contains("--perm-html") {
    let config = ConfigStore.load()
    print(HomePage.permissionsHTML(config: config, status: .current(config: config)))
    exit(0)
}

// 调试入口：--lemma <词库> <词> 只跑变形还原，输出查到的词典形
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--lemma" {
    guard let db = KrDict.debugOpen(CommandLine.arguments[2]) else {
        print("打不开词库"); exit(1)
    }
    let found = KrDict.lemmatize(db, CommandLine.arguments[3])
    print(found.map { $0.word + ($0.restored ? "*" : "") }.joined(separator: " "))
    exit(0)
}

// 调试入口：--krdict <词库> <词> 出整页 HTML，验证渲染
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--krdict" {
    guard let page = KrDict.page(database: URL(fileURLWithPath: CommandLine.arguments[2]),
                                 query: CommandLine.arguments[3], name: "词库"),
          let html = try? String(contentsOf: page, encoding: .utf8) else {
        print("渲染失败"); exit(1)
    }
    print(html)
    exit(0)
}

// 调试入口：--speak <文本> 直接跑朗读引擎，验证清洗、分节、语种、发声
if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--speak" || CommandLine.arguments[1] == "--speak-dry" {
    let config = ConfigStore.load()
    let text = CommandLine.arguments[2]
    for (i, stanza) in Speech.stanzas(of: text, skipNumbers: config.speechSkipsNumbers).enumerated() {
        for run in Speech.runs(of: stanza, config: config) {
            print("节\(i + 1) [\(run.language)] \(run.text)")
        }
    }
    if CommandLine.arguments[1] == "--speak-dry" { exit(0) }

    Speech.shared.speak(text, config: config)
    // 合成是异步的，等它读完
    while Speech.shared.isSpeaking || CFRunLoopRunInMode(.defaultMode, 0.2, false) == .handledSource {
        if !Speech.shared.isSpeaking { break }
    }
    Thread.sleep(forTimeInterval: 0.5)
    Speech.shared.shutdown()
    exit(0)
}


// 调试入口：打印解析后的配置和权限状态，不启动 GUI
if CommandLine.arguments.contains("--diag") {
    let config = ConfigStore.load()
    print("版本: \(appVersion)")
    print("界面语言: \(Bundle.main.preferredLocalizations.first ?? "?")"
        + "  可用: \(Bundle.main.localizations.sorted().joined(separator: ", "))")
    print("本地化自检: lang.ko = \"\(LanguageNames.display("ko"))\"  menu.lookup = \"\(t("menu.lookup"))\"")
    print("屏幕录制权限: \(CGPreflightScreenCaptureAccess() ? "已授权" : "未授权")")
    print("辅助功能权限: \(SelectionReader.isTrusted ? "已授权" : "未授权")")
    // 开机自启：特设签名的 App 注册登录项常常会失败，而失败是静默的 ——
    // 用户只会发现「开机没起来」，猜不到原因。所以写进自检。
    let loginStatus: String
    switch SMAppService.mainApp.status {
    case .enabled: loginStatus = "已启用"
    case .notRegistered: loginStatus = "未注册"
    case .notFound: loginStatus = "注册已失效（App 重新构建或移动过，重新勾一次即可）"
    case .requiresApproval: loginStatus = "等待用户在系统设置里批准"
    @unknown default: loginStatus = "未知"
    }
    print("开机自启: \(loginStatus)")
    let installed = LocalDictionaries.installed
    print("本机装了的词典 App: \(installed.isEmpty ? "无" : installed.map(\.name).joined(separator: ", "))")

    print("\n快捷键 (\(config.hotkeys.count) 条):")
    for binding in config.hotkeys {
        let source: String
        switch binding.captureSource {
        case .selection: source = "划词"
        case .screenshot: source = "截图"
        case .manual: source = "自输"
        case .home: source = "主页"
        }
        let detail: String
        switch binding.captureAction {
        case .clipboard: detail = "拼行后复制"
        case .qrcode: detail = "识别二维码"
        case .speak: detail = "朗读"
        case .speakFaster: detail = "朗读加速"
        case .speakSlower: detail = "朗读减速"
        case .lookup:
            detail = binding.targetDictionary
                .flatMap { id in config.dictionaries.first { $0.id == id }?.name ?? "⚠️ 找不到词典 \(id)" }
                ?? "自动"
        }
        let code = binding.resolvedKeyCode.map(String.init) ?? "⚠️ 无法解析键名"
        print("  \(binding.displayString.padding(toLength: 6, withPad: " ", startingAt: 0)) keyCode=\(code)  \(source) → \(detail)")
    }
    print("\n词典 (\(config.dictionaries.count) 个):")
    for (i, site) in config.dictionaries.enumerated() {
        print("  ⌘\(i + 1) \(site.name)\(site.external == true ? " ↗" : "")  \(site.languages.isEmpty ? "仅手动" : site.languages.joined(separator: ","))")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 常规应用：进程序坞、进 ⌘Tab、有自己的菜单栏。
// 菜单栏那个图标照旧留着 —— 两种入口并不冲突，很多常驻工具都是这样。
app.setActivationPolicy(.regular)
app.run()
