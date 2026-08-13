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

    /// 落盘的东西分两类，**清除时也分开**。
    ///
    /// 一股脑全清是最简单的写法，但那意味着「不想让词典站记住我搜过什么」
    /// 和「不想每次重新登录」这两件事只能二选一 —— 它们本来没有关系。
    enum Kind {
        /// Cookie。网站发的登录凭据就在这里，清掉等于登出。
        case logins
        /// 其余全部：缓存、localStorage（词典站的「最近搜索」存在这儿）、
        /// IndexedDB、Service Worker…… 清掉不影响登录。
        case browsing
        case all

        var types: Set<String> {
            let cookies: Set<String> = [WKWebsiteDataTypeCookies]
            switch self {
            case .logins: return cookies
            case .browsing: return WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cookies)
            case .all: return WKWebsiteDataStore.allWebsiteDataTypes()
            }
        }
    }

    static func clear(_ kind: Kind = .all, completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().removeData(ofTypes: kind.types,
                                                modifiedSince: .distantPast) {
            // URLCache 属于浏览数据，清登录时不该动它
            if kind != .logins { URLCache.shared.removeAllCachedResponses() }
            completion()
        }
    }

    /// 阻塞版，给 applicationWillTerminate 用。
    /// removeData 是异步的，不等它跑完进程就退出了，数据会留在盘上。
    static func clearBlocking(_ kind: Kind = .all, timeout: TimeInterval = 5) {
        var finished = false
        clear(kind) { finished = true }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// 哪些站点存了东西、存的是哪一类。让「存了什么」这件事看得见 ——
    /// 不然用户只能猜，而猜错的方向通常是「大概全都存了吧」。
    static func records(completion: @escaping ([(site: String, hasLogin: Bool)]) -> Void) {
        WKWebsiteDataStore.default()
            .fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { found in
            let list = found
                .map { (site: $0.displayName, hasLogin: $0.dataTypes.contains(WKWebsiteDataTypeCookies)) }
                .sorted { ($0.hasLogin ? 0 : 1, $0.site) < ($1.hasLogin ? 0 : 1, $1.site) }
            completion(list)
        }
    }
}
