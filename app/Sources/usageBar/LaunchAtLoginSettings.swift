import AppKit
import ServiceManagement
import SwiftUI

/// 开机自启（登录项）：包装 SMAppService.mainApp。
///
/// 默认开启策略（v0.3.28）：新装或升级后**首次启动**自动登记一次（UserDefaults 打标），
/// 之后完全尊重用户操作——无论在本设置页还是 系统设置→通用→登录项 里关掉，都不会被自动开回。
@MainActor
final class LaunchAtLoginSettings: ObservableObject {
    static let shared = LaunchAtLoginSettings()
    /// 「已自动开启过一次」标记——存在即不再自动登记（用户关掉后，升级/重启也不会被开回）
    private static let autoEnabledKey = "usagebar.launchAtLogin.autoEnabled.v1"

    /// UI 镜像；真值在系统登录项登记表里（SMAppService.status），refresh() 时回读
    @Published private(set) var isEnabled = false

    /// 登录项登记只对真正的 .app 包有意义；debug 裸可执行文件（swift build 产物）下开关置灰，
    /// 免得把开发产物登记进登录项、或开关"拨不动"被当成 bug
    nonisolated var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    private init() {
        refresh()
    }

    /// 从系统回读当前登记状态（设置页出现时调一次，捕捉用户在 系统设置→登录项 里的改动）
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // 登记失败不弹错（罕见，如系统策略拦截）；UI 回读真实状态，开关自然回弹
        }
        refresh()
    }

    /// 启动时调：首次启动（新装或升级后第一次）自动开启。
    /// 仅在真正的 .app 包里生效——debug 裸可执行文件（swift build 产物）绝不能把自己登记进登录项。
    func autoEnableOnce() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        guard !UserDefaults.standard.bool(forKey: Self.autoEnabledKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.autoEnabledKey)
        if !isEnabled { setEnabled(true) }
    }
}
