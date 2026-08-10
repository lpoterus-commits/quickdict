import Foundation
import Network

/// 有没有网。只为一件事服务：**断网时把查词转给本地词库**。
///
/// 用 `NWPathMonitor` 而不是查词时探一下 —— 探测要发真实请求，
/// 而查词最不能等的就是那几百毫秒。这里是后台持续更新，读的时候直接拿结果。
enum Reachability {
    private static let monitor = NWPathMonitor()
    private static let lock = NSLock()
    private static var satisfied = true      // 还没出结果时按「有网」走，别误伤

    static func start() {
        monitor.pathUpdateHandler = { path in
            lock.lock(); satisfied = path.status == .satisfied; lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.quickdict.net"))
    }

    static var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return satisfied
    }
}
