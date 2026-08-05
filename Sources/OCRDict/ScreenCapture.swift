import CoreGraphics
import Foundation
import ImageIO

enum ScreenCapture {
    enum Failure: Error {
        case cancelled          // 用户按了 esc
        case launchFailed(String)
        case decodeFailed
    }

    /// 拉起系统框选截图。阻塞直到用户选完或取消，请在后台队列调用。
    static func interactive() -> Result<CGImage, Failure> {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocrdict-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i 交互框选，-x 关闭快门声，-r 不写入屏幕元数据
        proc.arguments = ["-i", "-x", "-r", tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        // 取消时 screencapture 不落盘，文件不存在即视为取消
        guard let data = try? Data(contentsOf: tmp), !data.isEmpty else {
            return .failure(.cancelled)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return .failure(.decodeFailed)
        }
        return .success(image)
    }
}
