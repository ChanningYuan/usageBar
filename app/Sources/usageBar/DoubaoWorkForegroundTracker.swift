import AppKit
import usageBarProviders

/// 记下豆包工作在本机最前面的时段，交给 `DoubaoWorkLocalUseStore` 比对普通聊天的更新时间（v0.3.48）。
///
/// 普通聊天不带设备号、同账号各台电脑都会同步进来，只有「更新那一刻豆包工作正在这台电脑最前面」才算本机用过。
/// 只看哪个 App 在最前面，不需要任何系统权限。锁屏 / 睡眠时收口，免得一整夜都算「在前台」。
@MainActor
final class DoubaoWorkForegroundTracker {
    static let shared = DoubaoWorkForegroundTracker()

    /// 豆包工作此刻在最前面：从什么时候起；不在为 nil
    private(set) var openSince: Date?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        reopenIfFrontmost()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if bundleId == DoubaoWorkLocalUse.bundleIdentifier {
                    DoubaoWorkForegroundTracker.shared.open()
                } else {
                    DoubaoWorkForegroundTracker.shared.close()
                }
            }
        })
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DoubaoWorkForegroundTracker.shared.close() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DoubaoWorkForegroundTracker.shared.reopenIfFrontmost() }
            })
        }
    }

    private func reopenIfFrontmost() {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DoubaoWorkLocalUse.bundleIdentifier { open() }
    }

    private func open() {
        if openSince == nil { openSince = Date() }
    }

    private func close() {
        guard let since = openSince else { return }
        openSince = nil
        let interval = DateInterval(start: since, end: max(since, Date()))
        Task { await DoubaoWorkLocalUseStore.shared.noteForeground(interval) }
    }
}
