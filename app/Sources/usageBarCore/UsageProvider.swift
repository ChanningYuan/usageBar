import Foundation

/// Provider 协议（简化版）
///
/// 每个 Provider 只管"扫盘 + mtime 增量 + 返回按日聚合的 FileDailyRecord 数组"。
/// ViewModel 拿到所有 provider 的 FileDailyRecord 后，统一按窗口聚合成 StatRecord。
///
/// `family`：父级分组 id,Settings 树状 UI 用它做分组(同 family 的 provider 在 Settings
/// 里聚到同一 Section 头父级 Toggle 下,UI 渲染层不显示父级总和行,只渲染勾选的子项)。
/// 当前 family 用法:
///   - `claude-sub` / `claude-api` family="claude"
///   - `qoder-cli` / `qoder-work` / `qoder-ide` family="qoder"
///   - `codex` / `wukong` family=nil(独立 provider,Settings 自成一组)
public protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var iconSymbol: String { get }
    var brandColor: String { get }
    /// 父级分组 id,nil 表示该 provider 独立(Settings 里不归属任何父级)
    var family: String? { get }

    /// 扫该 provider 的所有数据文件，返回按 (provider, date) 聚合的所有 daily records。
    ///
    /// 实现建议：
    /// 1. 列出所有相关 jsonl 文件
    /// 2. 对每个文件取 mtime/size，查 FileMtimeCache.shared.lookup
    ///    - 命中 → 直接用 entry.records
    ///    - 未命中 → 解析文件，得到 [FileDailyRecord]，调 store(...) 存回缓存
    /// 3. 把所有文件的 records 合并返回
    func fetchDailyRecords() async throws -> [FileDailyRecord]
}

extension UsageProvider {
    /// 默认 family=nil(向后兼容,新增独立 provider 不需要显式实现)
    public var family: String? { nil }
}
