import Foundation
import SwiftUI
import usageBarProviders

/// Qoder token 统计开关的 UI 状态（@MainActor ObservableObject）。
///
/// 包一层 `QoderUsageEnvGate`（纯逻辑），给 `SettingsView` 的横幅和弹层提示行观察。
/// 状态来源：profile 标记块 + launchctl（见 `QoderUsageEnvGate`）。
///
/// Qoder CLI / QoderWork 使用 `QODER_EXPOSE_TOKEN_USAGE`；千问办公的 CN binary 使用
/// `QODERCN_EXPOSE_TOKEN_USAGE`。一键开启/撤销同时管理两行，但每个产品按自己的 gate 判定。
/// Qoder IDE 不受 gate，不在此跟踪。
/// 详见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md。
@MainActor
final class QoderUsageStatus: ObservableObject {
    static let shared = QoderUsageStatus()

    /// Qoder CLI 是否用过（`~/.qoder/projects` 有会话文件）。
    @Published private(set) var isCliPresent: Bool = false
    /// QoderWork 是否用过（`~/.qoderwork/projects` 有会话文件）。
    @Published private(set) var isWorkPresent: Bool = false
    /// 千问办公是否用过（`~/.qwenworkcn/projects` 有会话文件）。
    @Published private(set) var isQwenWorkPresent: Bool = false
    /// Qoder CLI / Work 的 gate。
    @Published private(set) var isQoderEnabled: Bool = false
    /// 千问办公 CN gate。
    @Published private(set) var isQwenWorkEnabled: Bool = false
    /// 所有已经用过的受控产品是否都已开启。
    @Published private(set) var isEnabled: Bool = false
    /// 写入 / 撤销失败时的错误提示。
    @Published var lastError: String?

    private init() { refresh() }

    /// 重新从 gate 读状态（presence + profile/launchctl 开关）。视图 onAppear / 每次 refresh 调。
    func refresh() {
        isCliPresent = QoderUsageEnvGate.isQoderCliPresent()
        isWorkPresent = QoderUsageEnvGate.isQoderWorkPresent()
        isQwenWorkPresent = QoderUsageEnvGate.isQwenWorkPresent()
        isQoderEnabled = QoderUsageEnvGate.isQoderEnabled()
        isQwenWorkEnabled = QoderUsageEnvGate.isQwenWorkEnabled()
        isEnabled = QoderUsageEnvGate.isEnabled()
    }

    /// 任一受 gate 的产品用过 → 才需要展示开关横幅。
    var isAnyGatedPresent: Bool { isCliPresent || isWorkPresent || isQwenWorkPresent }

    /// 一键开启：写 profile 标记块 + launchctl setenv（三个产品一次都开）。
    func enable() {
        if QoderUsageEnvGate.enable() {
            refresh()
            lastError = nil
        } else {
            lastError = "写入 \(QoderUsageEnvGate.profileDisplayName) 失败"
        }
    }

    /// 撤销：删 profile 标记块 + launchctl unsetenv。
    func disable() {
        if QoderUsageEnvGate.disable() {
            refresh()
            lastError = nil
        } else {
            lastError = "撤销失败"
        }
    }

    var profileDisplayName: String { QoderUsageEnvGate.profileDisplayName }
    var envExports: String {
        QoderUsageEnvGate.envNames.map { "export \($0)=1" }.joined(separator: "\n")
    }
}
