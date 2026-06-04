import AppKit
import SwiftUI

/// Settings 窗口管理(单例,右键菜单 → "偏好设置..." 触发)
///
/// 窗口非 modal,可独立打开关闭;关闭后再打开复用同一 window 实例(SwiftUI 状态保留)。
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func showWindow() {
        if let w = window {
            // 已有窗口 → 拉到前台
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settings: ProviderVisibilitySettings.shared)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "usageBar 偏好设置"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false  // close 后保留实例,二次打开复用
        w.setContentSize(NSSize(width: 460, height: 400))
        w.center()
        w.delegate = self
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        // 不释放,下次 showWindow 复用(避免 SwiftUI 状态丢失)
    }
}
