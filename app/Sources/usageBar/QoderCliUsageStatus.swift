import Foundation
import SwiftUI
import usageBarProviders

/// qodercli token 统计开关的 UI 状态（@MainActor ObservableObject）。
///
/// 包一层 `QoderUsageEnvGate`（纯逻辑），给 `SettingsView` 的横幅和弹层提示行观察。
/// 状态来源：profile 标记块 + launchctl（见 `QoderUsageEnvGate`）。
@MainActor
final class QoderCliUsageStatus: ObservableObject {
    static let shared = QoderCliUsageStatus()

    /// qodercli 是否用过（有会话文件）。false 时横幅 / 提示行完全不出现。
    @Published private(set) var isPresent: Bool = false
    /// token 统计是否已开启（profile / launchctl 有 =1）。
    @Published private(set) var isEnabled: Bool = false
    /// 写入 / 撤销失败时的错误提示。
    @Published var lastError: String?

    private init() { refresh() }

    /// 重新从 gate 读状态（profile + launchctl）。视图 onAppear 调。
    func refresh() {
        isPresent = QoderUsageEnvGate.isQoderCliPresent()
        isEnabled = QoderUsageEnvGate.isEnabled()
    }

    /// 一键开启：写 profile 标记块 + launchctl setenv。
    func enable() {
        if QoderUsageEnvGate.enable() {
            isEnabled = true
            lastError = nil
        } else {
            lastError = "写入 \(QoderUsageEnvGate.profileDisplayName) 失败"
        }
    }

    /// 撤销：删 profile 标记块 + launchctl unsetenv。
    func disable() {
        if QoderUsageEnvGate.disable() {
            isEnabled = false
            lastError = nil
        } else {
            lastError = "撤销失败"
        }
    }

    var profileDisplayName: String { QoderUsageEnvGate.profileDisplayName }
    var envName: String { QoderUsageEnvGate.envName }
}
