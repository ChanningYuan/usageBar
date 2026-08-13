import Foundation
import SwiftUI
import usageBarProviders

/// Qoder token 统计开关的 UI 状态（@MainActor ObservableObject）。
///
/// 包一层 `QoderUsageEnvGate`（纯逻辑），给 `SettingsView` 的横幅和弹层提示行观察。
/// 状态来源：profile 标记块 + launchctl（见 `QoderUsageEnvGate`）。
///
/// Qoder CLI 使用 `QODER_EXPOSE_TOKEN_USAGE`；千问办公的 CN binary 使用
/// `QODERCN_EXPOSE_TOKEN_USAGE`。一键开启/撤销同时管理两行，但每个产品按自己的 gate 判定。
/// Qoder IDE 不受 gate，不在此跟踪。
/// 详见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md。
@MainActor
final class QoderUsageStatus: ObservableObject {
    static let shared = QoderUsageStatus()

    /// Qoder CLI 是否用过（`~/.qoder/projects` 有会话文件）。
    @Published private(set) var isCliPresent: Bool = false
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
    /// providerId → 最近一次写会话日志的时间（不看 token 是否为 0）。
    ///
    /// 用来区分「今天没用过」和「用了但 gate 没生效」——见 `QoderUsageEnvGate.latestSessionActivity`。
    /// 在这里缓存是因为它要扫盘，**不能**在 SwiftUI body 里按需调用。
    @Published private(set) var latestActivity: [String: Date] = [:]

    private init() { refresh() }

    /// 重新从 gate 读状态（presence + profile/launchctl 开关 + 日志活动时间）。
    /// 视图 onAppear / 每次 refresh 调。
    func refresh() {
        // launchctl 自愈（issue #3）：重启电脑后 launchctl 值会丢，QoderWork 读 shell 环境一旦
        // 超时回退就拿不到 gate → 在这里顺带补写。spawn 进程，放后台跑，不阻塞主线程。
        Task.detached(priority: .utility) { QoderUsageEnvGate.selfHealLaunchctl() }
        isCliPresent = QoderUsageEnvGate.isQoderCliPresent()
        isQwenWorkPresent = QoderUsageEnvGate.isQwenWorkPresent()
        isQoderEnabled = QoderUsageEnvGate.isQoderEnabled()
        isQwenWorkEnabled = QoderUsageEnvGate.isQwenWorkEnabled()
        isEnabled = QoderUsageEnvGate.isEnabled()
        latestActivity = ["qoder-cli", "qwen-work"]
            .reduce(into: [:]) { result, pid in
                result[pid] = QoderUsageEnvGate.latestSessionActivity(for: pid)
            }
    }

    /// 任一受 gate 的产品用过 → 才需要展示开关横幅。
    var isAnyGatedPresent: Bool { isCliPresent || isQwenWorkPresent }

    /// 一键开启：写 profile 标记块 + launchctl setenv（两个产品一次都开）。
    func enable() {
        apply(QoderUsageEnvGate.enable(), failure: "写入 \(QoderUsageEnvGate.profileDisplayName) 失败")
    }

    /// 撤销：删 profile 标记块 + launchctl unsetenv（全部）。
    func disable() {
        apply(QoderUsageEnvGate.disable(), failure: "撤销失败")
    }

    /// 只开启某个产品的 gate（v0.3.33：两个产品各开各的）。
    /// `product` = "qoder-cli" / "qwen-work"。
    func enable(product: String) {
        apply(QoderUsageEnvGate.enable(Self.envName(for: product)),
              failure: "写入 \(QoderUsageEnvGate.profileDisplayName) 失败")
    }

    /// 只撤销某个产品的 gate（另一个若已开则保持不变）。
    func disable(product: String) {
        apply(QoderUsageEnvGate.disable(Self.envName(for: product)), failure: "撤销失败")
    }

    private static func envName(for product: String) -> String {
        product == "qwen-work" ? QoderUsageEnvGate.qwenWorkEnvName : QoderUsageEnvGate.qoderEnvName
    }

    private func apply(_ ok: Bool, failure: String) {
        if ok {
            refresh()
            lastError = nil
        } else {
            lastError = failure
        }
    }

    var profileDisplayName: String { QoderUsageEnvGate.profileDisplayName }
    var envExports: String {
        QoderUsageEnvGate.envNames.map { "export \($0)=1" }.joined(separator: "\n")
    }
}
