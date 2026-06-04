import AppKit
import usageBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory：不在 Dock 显示、不抢焦点、不进 Cmd+Tab
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }

    /// 退出前把 mtime 缓存 dump 到磁盘
    func applicationWillTerminate(_ notification: Notification) {
        // 同步等待 cache 写完（确保不丢）
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await FileMtimeCache.shared.saveToDisk()
            semaphore.signal()
        }
        // 最多等 2 秒（避免卡退出）
        _ = semaphore.wait(timeout: .now() + 2)
    }
}
