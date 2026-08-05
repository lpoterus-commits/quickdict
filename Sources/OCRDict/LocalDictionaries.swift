import AppKit

/// 本机安装的词典 App。
///
/// 查词不一定要开网页 —— 很多词典软件注册了自己的 URL scheme，
/// `NSWorkspace.open` 对任何 scheme 都有效，所以只要把词典项标成 `external`
/// 并把 url 写成 `eudic://dict/{q}` 这种形式，就会跳到本地 App 而不是浏览器。
///
/// 这里只做一件事：**探测哪些真的装了**，把装了的列进菜单让用户勾。
/// 没装的不显示 —— 列一堆点了没反应的选项比不列更糟。
enum LocalDictionaries {
    struct Entry {
        var id: String
        var name: String
        /// 用来探测的 scheme，例如 "eudic"
        var scheme: String
        /// {q} 是查询词的位置
        var urlTemplate: String
    }

    /// URL 模板只有系统「词典」是本机实测过的；其余几个按各家公开的 scheme 写，
    /// 装了之后如果跳转不对，改配置里那一条的 url 即可。
    static let known: [Entry] = [
        Entry(id: "local-dict", name: "Dictionary.app", scheme: "dict",
              urlTemplate: "dict://{q}"),
        Entry(id: "local-eudic", name: "Eudic", scheme: "eudic",
              urlTemplate: "eudic://dict/{q}"),
        Entry(id: "local-goldendict", name: "GoldenDict", scheme: "goldendict",
              urlTemplate: "goldendict://{q}"),
        Entry(id: "local-mdict", name: "MDict", scheme: "mdict",
              urlTemplate: "mdict://{q}"),
        Entry(id: "local-bob", name: "Bob", scheme: "bob",
              urlTemplate: "bob://translate?t={q}"),
    ]

    /// 本机真的有处理程序的那些
    static var installed: [Entry] {
        known.filter { entry in
            guard let probe = URL(string: "\(entry.scheme)://probe") else { return false }
            return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
        }
    }

    /// 本地 App 必须走 external —— 内嵌 WebView 加载不了自定义 scheme
    static func site(for entry: Entry) -> DictSite {
        DictSite(id: entry.id, name: entry.name, languages: [],
                 url: entry.urlTemplate, suffix: nil, external: true)
    }

    static var allIDs: Set<String> { Set(known.map(\.id)) }
}
