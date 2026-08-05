import Foundation

/// Markdown 笔记的转换缓存。
///
/// 词典指向 `.md` 时，真正加载的是转换出来的 HTML。转换按需发生，
/// 并且**跟着源文件的修改时间走** —— 改完笔记直接查就是新的，不用手动重新生成。
enum NotesCache {

    private static var directory: URL {
        let dir = ConfigStore.directory.appendingPathComponent("notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 指向 `.md` 就换成缓存的 HTML，其余原样返回。
    ///
    /// 查询串挂在 URL 上（`?q=…`），换文件时要原样搬过去。
    static func resolve(_ url: URL, site: DictSite) -> URL {
        guard url.isFileURL else { return url }
        // 有资料清单就以它为准；否则回落到 url 里的那个路径（旧配置就是这样写的）
        let roots = site.notes ?? [url.path]
        // 经副本库解析：原件在就用原件（最新），不在就用副本顶上
        let notes = NotesLibrary.resolve(sources: roots)
        guard !notes.isEmpty else { return url }

        let cached = convert(notes, label: URL(fileURLWithPath: site.id))
        guard var parts = URLComponents(url: cached, resolvingAgainstBaseURL: false) else { return url }
        parts.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
        return parts.url ?? cached
    }

    /// 缓存文件名带上源路径的散列，避免同名文件互相覆盖
    private static func convert(_ notes: [URL], label: URL) -> URL {
        let stamp = NotesLibrary.stableHash(label.path)
        let target = directory.appendingPathComponent(
            "\(label.deletingPathExtension().lastPathComponent)-\(stamp).html")

        if isFresh(target, comparedTo: notes) { return target }
        let html = Notes.html(from: notes)
        try? html.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// 任何一份源文件比缓存新就要重转 —— 改完笔记直接查就是新的
    private static func isFresh(_ cached: URL, comparedTo notes: [URL]) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cached.path),
              let cachedAt = (try? fm.attributesOfItem(atPath: cached.path))?[.modificationDate] as? Date
        else { return false }
        return notes.allSatisfy { note in
            guard let at = (try? fm.attributesOfItem(atPath: note.path))?[.modificationDate] as? Date
            else { return true }
            return cachedAt >= at
        }
    }

    /// 资料清单变了要强制重转。
    ///
    /// 只看修改时间是不够的：加进来的旧文件时间戳比缓存还早，移除更是不改任何文件时间，
    /// 两种情况下缓存都会被判成「新鲜」。
    static func invalidate(_ site: DictSite) {
        let label = (site.notes ?? []).isEmpty
            ? URL(fileURLWithPath: URL(string: site.url)?.path ?? site.id)
            : URL(fileURLWithPath: site.id)
        let target = directory.appendingPathComponent(
            "\(label.deletingPathExtension().lastPathComponent)-\(NotesLibrary.stableHash(label.path)).html")
        try? FileManager.default.removeItem(at: target)
    }

    /// 清除浏览数据时一并清掉 —— 这些是能重新生成的派生物
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 副本也一起清（原件还在的话，下次查会自动重新拷）
    static func clearAll() {
        clear()
        NotesLibrary.clear()
    }
}
