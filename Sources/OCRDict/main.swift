import AppKit
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

// 调试入口：打印解析后的配置和权限状态，不启动 GUI
if CommandLine.arguments.contains("--diag") {
    let config = ConfigStore.load()
    print("版本: \(appVersion)")
    print("界面语言: \(Bundle.main.preferredLocalizations.first ?? "?")"
        + "  可用: \(Bundle.main.localizations.sorted().joined(separator: ", "))")
    print("本地化自检: lang.ko = \"\(LanguageNames.display("ko"))\"  menu.lookup = \"\(t("menu.lookup"))\"")
    print("屏幕录制权限: \(CGPreflightScreenCaptureAccess() ? "已授权" : "未授权")")
    print("辅助功能权限: \(SelectionReader.isTrusted ? "已授权" : "未授权")")
    print("\n快捷键 (\(config.hotkeys.count) 条):")
    for binding in config.hotkeys {
        let source = binding.captureSource == .selection ? "划词" : "截图"
        let detail: String
        switch binding.captureAction {
        case .clipboard: detail = "拼行后复制"
        case .qrcode: detail = "识别二维码"
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
app.setActivationPolicy(.accessory) // 菜单栏常驻，不占 Dock、不进 ⌘Tab
app.run()
