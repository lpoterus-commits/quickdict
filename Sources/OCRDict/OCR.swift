import CoreGraphics
import Foundation
import Vision

/// 一行识别结果 + 它在图上的位置。位置是拼行时判断「这行是被挤断的还是自然结束」的唯一依据。
struct OCRLine {
    var text: String
    /// 归一化坐标，原点在左下
    var box: CGRect
}

enum OCR {
    private struct Pass {
        var text: String
        var confidence: Float
        var lines: [OCRLine]
    }

    /// 保留分行和几何信息的识别，供剪贴板模式拼行用
    static func recognizeLines(image: CGImage, languages: [String], autoDetect: Bool) -> [OCRLine] {
        if autoDetect {
            let pass = perform(image: image, languages: languages, auto: true)
            if !pass.lines.isEmpty { return pass.lines }
        }
        var best: Pass?
        for language in languages {
            let pass = perform(image: image, languages: [language], auto: false)
            guard !pass.lines.isEmpty else { continue }
            if best == nil || pass.confidence > best!.confidence { best = pass }
        }
        return best?.lines ?? perform(image: image, languages: [], auto: false).lines
    }

    /// 按阅读顺序返回识别到的所有行，用 \n 连接。识别不到返回空串。
    ///
    /// 注意：不能简单地把 ["en-US","ko-KR","zh-Hans"] 塞进 recognitionLanguages —— 实测拉丁语和
    /// CJK 混在一个列表里时，Vision 对 CJK 会直接返回空。正确做法是开 automaticallyDetectsLanguage
    /// 让它自己选模型；只有在自动识别也落空时，才逐语言重试并取置信度最高的那次。
    static func recognize(image: CGImage, languages: [String], autoDetect: Bool) -> String {
        if autoDetect {
            let pass = perform(image: image, languages: languages, auto: true)
            if !pass.text.isEmpty { return pass.text }
        }

        var best: Pass?
        for language in languages {
            let pass = perform(image: image, languages: [language], auto: false)
            guard !pass.text.isEmpty else { continue }
            if best == nil || pass.confidence > best!.confidence { best = pass }
        }
        if let best { return best.text }

        return perform(image: image, languages: [], auto: false).text
    }

    private static func perform(image: CGImage, languages: [String], auto: Bool) -> Pass {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = auto

        // 配置里可能写了当前系统不支持的语言，先过滤掉
        if !languages.isEmpty, let supported = try? request.supportedRecognitionLanguages() {
            let wanted = languages.filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[OCRDict] OCR 失败: \(error)")
            return Pass(text: "", confidence: 0, lines: [])
        }

        let observations = request.results ?? []
        // Vision 不保证返回顺序，自己按「先上后下、再左到右」排一遍
        let ordered = observations.sorted { a, b in
            let ay = a.boundingBox.midY, by = b.boundingBox.midY
            if abs(ay - by) > 0.02 { return ay > by }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let lines: [OCRLine] = ordered.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: best.string, box: observation.boundingBox)
        }
        let candidates = ordered.compactMap { $0.topCandidates(1).first }
        guard !candidates.isEmpty else { return Pass(text: "", confidence: 0, lines: []) }

        let text = candidates.map(\.string).joined(separator: "\n")
        let mean = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
        return Pass(text: text, confidence: mean, lines: lines)
    }

    /// 当前系统 Vision 支持的识别语言，用于菜单里的自检
    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }
}

enum TextClean {
    /// 折叠 OCR 带出来的换行与多余空格
    static func normalize(_ text: String, collapseToSpace: Bool) -> String {
        let replacement = collapseToSpace ? " " : ""
        return text
            .replacingOccurrences(of: "\\s+", with: replacement, options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
