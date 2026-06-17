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
    /// "claude-sub" / "claude-api" / "qoder-cli" / "qoder-work" / "qoder-ide" / "codex" / "wukong"
    public let provider: String
    /// "2026-05-20" 本地日期（按 Asia/Shanghai）
    public let date: String
    public let token: Int

    public init(provider: String, date: String, token: Int) {
        self.provider = provider
        self.date = date
        self.token = token
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
    public static let currentSchemaVersion = 3

    public init(entries: [FileCacheEntry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.savedAt = Date()
        self.entries = entries
    }
}
