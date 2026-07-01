import Foundation
import SwiftUI
import usageBarProviders

/// Qoder token 统计开关的 UI 状态（@MainActor ObservableObject）。
///
/// 包一层 `QoderUsageEnvGate`（纯逻辑），给 `SettingsView` 的横幅和弹层提示行观察。
/// 状态来源：profile 标记块 + launchctl（见 `QoderUsageEnvGate`）。
///
/// gate 是 family 级的：**一个 `QODER_EXPOSE_TOKEN_USAGE` 同时覆盖 Qoder CLI 和 QoderWork**
/// （二者共用同款 agent SDK）。所以 `isEnabled` / `enable` / `disable` 是共享的，只有"用过没用过"
/// 按产品分（`isCliPresent` / `isWorkPresent`）。Qoder IDE 不受 gate，不在此跟踪。
/// 详见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md。
@MainActor
final class QoderUsageStatus: ObservableObject {
    static let shared = QoderUsageStatus()

    /// Qoder CLI 是否用过（`~/.qoder/projects` 有会话文件）。
    @Published private(set) var isCliPresent: Bool = false
    /// QoderWork 是否用过（`~/.qoderwork/projects` 有会话文件）。
    @Published private(set) var isWorkPresent: Bool = false
    /// token 统计是否已开启（profile / launchctl 有 =1）。CLI 与 Work 共用此状态。
    @Published private(set) var isEnabled: Bool = false
    /// 写入 / 撤销失败时的错误提示。
    @Published var lastError: String?

    private init() { refresh() }

    /// 重新从 gate 读状态（presence + profile/launchctl 开关）。视图 onAppear / 每次 refresh 调。
    func refresh() {
        isCliPresent = QoderUsageEnvGate.isQoderCliPresent()
        isWorkPresent = QoderUsageEnvGate.isQoderWorkPresent()
        isEnabled = QoderUsageEnvGate.isEnabled()
    }

    /// 任一受 gate 的产品（CLI / Work）用过 → 才需要展示开关横幅。
    var isAnyGatedPresent: Bool { isCliPresent || isWorkPresent }

    /// 一键开启：写 profile 标记块 + launchctl setenv（CLI 和 Work 一次都开）。
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
