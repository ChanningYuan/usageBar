import Foundation

/// 单个 jsonl 文件的解析结果缓存
///
/// 每个 jsonl 文件对应一条 FileCacheEntry，存 mtime + size + 按日按 provider 聚合的 records。
/// 下次扫盘时对比 mtime/size，没变就直接复用 records，避免重复 JSON parse。
public struct FileCacheEntry: Codable, Sendable, Equatable {
    /// 文件绝对路径（同时是缓存 key）
    public let filePath: String
    /// 上次扫描时的修改时间
    public let mtime: Date
    /// 上次扫描时的字节数
    public let size: Int
    /// 按 (provider, date) 聚合后的 token 数
    public let records: [FileDailyRecord]

    public init(filePath: String, mtime: Date, size: Int, records: [FileDailyRecord]) {
        self.filePath = filePath
        self.mtime = mtime
        self.size = size
        self.records = records
    }
}

/// 单文件内"某 provider 在某天的总 token"
public struct FileDailyRecord: Codable, Sendable, Equatable {
    /// "claude-code" / "cowork" / "qoder-cli" / "qoder-work" / "qoder-ide" / "codex" / "wukong"
    public let provider: String
    /// "2026-05-20" 本地日期（按 Asia/Shanghai）
    public let date: String
    public let token: Int
    /// token 里「缓存命中读取」的分量（双色进度条浅色段用）；无缓存 provider 为 0
    public let cachedToken: Int

    public init(provider: String, date: String, token: Int, cachedToken: Int = 0) {
        self.provider = provider
        self.date = date
        self.token = token
        self.cachedToken = cachedToken
    }
}

/// 持久化到磁盘的 cache 文件 schema
public struct PersistedCache: Codable, Sendable {
    /// 版本号。schema 改了 +1，旧文件直接丢弃重扫
    public let schemaVersion: Int
    public let savedAt: Date
    public let entries: [FileCacheEntry]

    /// 版本变更日志:
    ///   1 → 2 (2026-05-25): provider id 改为连字符格式(如 `claude-sub` / `qoder-cli`)。
    ///                        bump 让所有旧 cache 自动失效,避免新代码 filter 不到旧 records 全显 0。
    ///   2 → 3 (2026-06-15): Claude transcript 解析改为按 message.id 去重(流式重复落盘的同一响应
    ///                        只计一次)。旧 cache 是逐行累加的放大值(约 2-3x),必须失效重算。
    ///   3 → 4 (2026-07-01): FileDailyRecord 加 cachedToken(缓存命中分量,双色进度条用)。旧 cache
    ///                        无此字段,失效重扫一次。
    ///   4 → 5 (2026-07-02): 悟空 provider 新增 cacheTokens 解析(v0.3.11)。v0.3.10 把悟空 records
    ///                        存成 cachedToken=0,不 bump 则升级后 mtime 未变的悟空文件仍命中旧 0 值、
    ///                        新解析不跑 → 命中率恒 0%。bump 让旧 cache 失效重扫一次。
    ///   5 → 6 (2026-07-10): Codex 事件总量口径改为 input+output(与详情页统一),排除 Codex Desktop
    ///                        「从其他 AI 应用导入」replay 快照被计入导入当天。旧 cache 按 total_tokens
    ///                        算、含误计的导入量,必须失效重算。
    ///   6 → 7 (2026-07-13): Claude Code 的 `claude-sub` / `claude-api` 合并为 `claude-code`。
    ///                        旧 cache 仍存拆分 id,不失效会让新 provider filter 不到历史记录全显 0。
    /// v8（v0.3.22）：Cursor 聚合口径改为「同 (时间戳,模型) 取终值」，旧的聚合结果全部作废。
    /// 不 bump 的话，用户升级后 Cursor 的数字不会自己变对（旧结果还躺在缓存里）。
    public static let currentSchemaVersion = 8

    public init(entries: [FileCacheEntry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.savedAt = Date()
        self.entries = entries
    }
}
