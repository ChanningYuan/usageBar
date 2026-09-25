import Foundation
import SwiftUI

/// 账号额度监测开关（v0.3.24，持久化 UserDefaults）。
///
/// 逻辑开关：`codex` / `claude-code` / `qoder` / `qwen-work` / `doubao-work` / `cursor` / `workbuddy`。
/// - Codex **默认开**（纯本地读日志，零联网、零风险）。
/// - Claude / Qoder / 千问办公 **默认关**——首次开启涉及联网和/或读系统钥匙串，
///   让用户主动开、并预告代价（见设置说明文案）。
///
/// Qoder 是一个逻辑开关，但覆盖三个 provider 实例（CLI / Work / IDE 共享账号额度）。
@MainActor
final class RateLimitSettings: ObservableObject {
    static let shared = RateLimitSettings()

    /// 逻辑开关 id（≠ provider 实例 id：qoder 覆盖三实例）
    static let logicalIds = ["codex", "claude-code", "qoder", "qwen-work", "doubao-work", "cursor", "workbuddy"]
    /// 默认开：零钥匙串的三个（Codex 读日志、WorkBuddy 读明文文件、Cursor 读明文 SQLite）。
    /// Claude / Qoder / 千问办公 / 豆包工作涉及钥匙串授权，默认关，让用户主动开 + 走引导。
    /// ⚠️ 豆包工作的额度**和积分**都靠这一个开关（没有本地日志可读）：关着时主列表那一行没有数，只挂「去开启」。
    static let defaultEnabled: Set<String> = ["codex", "workbuddy", "cursor"]

    @Published private(set) var enabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabled), forKey: Keys.enabled) }
    }

    /// 每个逻辑 provider 选用的数据源（只有 Claude 有多选：statusline/cli/oauth）。
    /// 其余 provider 数据源唯一，不进这个 dict。Qoder 是 API + 自动降级，reader 内部处理，也不进。
    @Published private(set) var dataSources: [String: String] {
        didSet { UserDefaults.standard.set(dataSources, forKey: Keys.dataSources) }
    }

    /// 已完整走过引导配置的逻辑开关（曾确认过一次）。用于**再次开启时不重弹引导 sheet**——
    /// 用户配置过、授权过一次后，关掉再开还弹引导框很奇怪（用户反馈）。
    @Published private(set) var configured: Set<String> {
        didSet { UserDefaults.standard.set(Array(configured), forKey: Keys.configured) }
    }

    /// Claude 数据源三选，默认 statusline（零弹窗、零副作用）
    static let claudeSources = ["statusline", "cli", "oauth"]
    static let defaultDataSources = ["claude-code": "statusline"]

    /// 千问办公「精确模式 · 读取 Chrome 里的网页登录」（v0.3.38）。默认关：开了才碰 Chrome 的 cookie 库
    /// （首次弹一次「Chrome Safe Storage」钥匙串授权）。只影响详情页的「今日已用 / 按会话积分」，
    /// 主列表三颗药丸（每日 / 周期 / 长期）走桌面令牌，与它无关。
    @Published private(set) var qwenWorkPreciseMode: Bool {
        didSet { UserDefaults.standard.set(qwenWorkPreciseMode, forKey: Keys.qwenWorkPreciseMode) }
    }

    private enum Keys {
        static let enabled = "usagebar.rateLimitEnabled.v1"
        static let dataSources = "usagebar.rateLimitDataSources.v1"
        static let configured = "usagebar.rateLimitConfigured.v1"
        static let qwenWorkPreciseMode = "usagebar.qwenWorkPreciseMode.v1"
    }

    func setQwenWorkPreciseMode(_ on: Bool) {
        guard qwenWorkPreciseMode != on else { return }
        qwenWorkPreciseMode = on
    }

    private init() {
        qwenWorkPreciseMode = UserDefaults.standard.bool(forKey: Keys.qwenWorkPreciseMode)
        if let arr = UserDefaults.standard.array(forKey: Keys.enabled) as? [String] {
            enabled = Set(arr.filter { Self.logicalIds.contains($0) })
        } else {
            enabled = Self.defaultEnabled
        }
        if let d = UserDefaults.standard.dictionary(forKey: Keys.dataSources) as? [String: String] {
            dataSources = d
        } else {
            dataSources = Self.defaultDataSources
        }
        configured = Set((UserDefaults.standard.array(forKey: Keys.configured) as? [String]) ?? [])
    }

    /// 该逻辑开关是否已完整配置过一次（决定再次开启要不要弹引导 sheet）
    func isConfigured(_ logicalId: String) -> Bool { configured.contains(logicalId) }
    func markConfigured(_ logicalId: String) { configured.insert(logicalId) }
    /// 取消授权/重置：清掉已配置标记 → 下次开启重新走引导 + 重新授权
    func clearConfigured(_ logicalId: String) { configured.remove(logicalId) }

    /// 某逻辑 provider 选中的数据源（未设则用默认）
    func dataSource(for logicalId: String) -> String {
        dataSources[logicalId] ?? Self.defaultDataSources[logicalId] ?? ""
    }

    func setDataSource(for logicalId: String, _ source: String) {
        dataSources[logicalId] = source
    }

    func isEnabled(_ logicalId: String) -> Bool { enabled.contains(logicalId) }

    /// 某 provider 实例对应的逻辑额度开关 id（qoder-* → "qoder"）；无额度数据源返回 nil。
    ///
    /// ⚠️ 千问办公**返回自身**（初版在这里返回 nil，副作用是主列表药丸永远不出现）。它确实有「当前状态」
    /// 数据源——`/user/balance` 的剩余可用。详情页要不要画额度模块由 `ProviderDetailSpec.hasQuotaModule`
    /// 单独声明，不靠这里返回 nil 间接关掉——那会把药丸和设置页状态一并关掉。
    static func logicalKey(forProvider pid: String) -> String? {
        if pid.hasPrefix("qoder-") { return "qoder" }
        if logicalIds.contains(pid) { return pid }
        return nil
    }

    /// 某 provider 实例是否已开启额度监测
    func isEnabled(forProvider pid: String) -> Bool {
        guard let key = Self.logicalKey(forProvider: pid) else { return false }
        return isEnabled(key)
    }

    /// 开/关。返回是否发生了变化（调用方据此决定要不要立即采一次 / 清快照）。
    @discardableResult
    func setEnabled(_ logicalId: String, _ on: Bool) -> Bool {
        let was = enabled.contains(logicalId)
        guard was != on else { return false }
        if on { enabled.insert(logicalId) } else { enabled.remove(logicalId) }
        return true
    }
}
