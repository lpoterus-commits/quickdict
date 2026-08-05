import Foundation

/// 本地资料的副本库。
///
/// 词典记的是**原文件的路径**，所以你改完笔记直接查就是新的 —— 这一条不能丢。
/// 但只记路径也有代价：文件一挪窝、一改名、一删，词典就断了。
///
/// 所以两者都要：读的时候用原文件（最新），同时在 App 自己的目录里留一份副本。
/// 原文件还在 → 用它，顺手把副本刷新；原文件不在了 → 用副本，词典照常能查。
///
/// 副本放在 `<配置目录>/sources/`，文件名带上原路径的散列，避免同名互相覆盖。
enum NotesLibrary {

    static var directory: URL {
        let dir = ConfigStore.directory.appendingPathComponent("sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// 路径统一成 NFC 再比较。
    ///
    /// macOS 的文件 API 返回的路径是**分解形式**（NFD），而配置文件里存的是写入时的
    /// 形式（通常 NFC）。两者指向同一个文件，`FileManager` 也照样打得开，
    /// 但**字符串相等和前缀判断会失败** —— 路径里有韩文或中文时尤其明显。
    /// 实测：索引里 6 条全部判成「不在扫描结果里」，回收因此一条也没执行。
    private static func norm(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// 原文件路径 → 副本文件名
    private static func loadIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private static func save(_ index: [String: String]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 把资料清单解析成实际要读的 `.md` 文件，同时维护副本。
    ///
    /// - Parameter sources: 用户添加的路径，可以是 `.md` 文件也可以是文件夹
    static func resolve(sources: [String]) -> [URL] {
        let before = loadIndex()
        var index = before
        var result: [URL] = []
        // 能读到的来源，就知道它当下到底有哪些文件 —— 记录下来好回收旧的
        var scanned: [String] = []
        var live: Set<String> = []

        for raw in sources {
            let source = norm(raw)
            let files = markdownFiles(at: source)
            if files.isEmpty {
                // 原件不可达 —— 把当初从这个来源收进来的副本顶上
                let prefix = source.hasSuffix("/") ? source : source + "/"
                for (original, copy) in index.sorted(by: { $0.key < $1.key })
                where original == source || original.hasPrefix(prefix) {
                    let url = directory.appendingPathComponent(copy)
                    if FileManager.default.fileExists(atPath: url.path) { result.append(url) }
                }
                continue
            }
            scanned.append(source)
            for file in files {
                let key = norm(file.path)
                index[key] = refreshCopy(of: file).lastPathComponent
                live.insert(key)
                result.append(file)
            }
        }

        collectGarbage(&index, scanned: scanned, live: live)
        // 内容没变就别写 —— 每次查词都重写一遍这个文件没有意义
        if index != before { save(index) }
        return result
    }

    /// 清理副本目录。
    ///
    /// 两种垃圾都要管：
    /// - **索引里指向已消失文件的条目** —— 原件改名或删除会留下
    /// - **目录里没被索引引用的文件** —— 索引本身丢过、或换过命名规则会留下
    ///
    /// 后一种靠遍历索引是永远碰不到的：它已经不在索引里了。所以反过来做 ——
    /// **索引是权威，目录扫一遍对齐**。
    ///
    /// 只在**至少扫到一个来源**时清。全都读不到时说明可能是硬盘没挂载之类，
    /// 那正是要靠副本顶上的时候，一个都不能删。
    private static func collectGarbage(_ index: inout [String: String],
                                       scanned: [String], live: Set<String>) {
        guard !scanned.isEmpty else { return }

        for (original, _) in index where !live.contains(original) {
            let covered = scanned.contains {
                original == $0 || original.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
            }
            if covered { index[original] = nil }
        }

        let referenced = Set(index.values)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing where name.hasSuffix(".md") && !referenced.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// 副本比原件旧就重拷一份
    private static func refreshCopy(of original: URL) -> URL {
        let name = "\(stableHash(norm(original.path)))-\(original.lastPathComponent)"
        let copy = directory.appendingPathComponent(name)
        let fm = FileManager.default

        let originalAt = (try? fm.attributesOfItem(atPath: original.path))?[.modificationDate] as? Date
        let copyAt = (try? fm.attributesOfItem(atPath: copy.path))?[.modificationDate] as? Date
        if let copyAt, let originalAt, copyAt >= originalAt { return copy }

        try? fm.removeItem(at: copy)
        try? fm.copyItem(at: original, to: copy)
        return copy
    }

    /// 文件就是它自己；文件夹就取里面的 `.md`（不递归 —— 免得把整个文稿库吸进来）
    static func markdownFiles(at path: String) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        let url = URL(fileURLWithPath: path)
        guard isDirectory.boolValue else {
            return url.pathExtension.lowercased() == "md" ? [url] : []
        }
        let inside = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return inside.filter { $0.pathExtension.lowercased() == "md" }
                     .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }


    /// 路径的稳定散列。
    ///
    /// **不能用 `String.hashValue`** —— Swift 每个进程的哈希种子是随机的，
    /// 文件名会一次一变，结果是每次启动都重做一遍并留下一堆垃圾。这里用 FNV-1a。
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// 清理：副本是派生物，清掉还能再生成（只要原件还在）
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
