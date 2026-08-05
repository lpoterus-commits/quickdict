import Foundation
import WebKit

/// 内嵌 WebView 的落盘数据管理。
///
/// WKWebView 默认用持久化存储，Cookie / localStorage / 缓存都会留在
/// ~/Library/WebKit/<bundleID>/ 和 ~/Library/Caches/<bundleID>/ 里，
/// 词典站点的「最近搜索」就存在 localStorage 中 —— 本 App 自己不记任何历史，
/// 但网站会记，所以需要主动清。
enum WebData {
    static var directories: [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.poterus.ocrdict"
        return [
            library.appendingPathComponent("WebKit/\(bundleID)"),
            library.appendingPathComponent("Caches/\(bundleID)"),
        ]
    }

    static func diskUsage() -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var total: Int64 = 0
        for directory in directories {
            guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func clear(completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            URLCache.shared.removeAllCachedResponses()
            completion()
        }
    }

    /// 阻塞版，给 applicationWillTerminate 用。
    /// removeData 是异步的，不等它跑完进程就退出了，数据会留在盘上。
    static func clearBlocking(timeout: TimeInterval = 5) {
        var finished = false
        clear { finished = true }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
