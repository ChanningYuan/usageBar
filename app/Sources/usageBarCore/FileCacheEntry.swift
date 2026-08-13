import Foundation

/// 单个源文件的解析结果缓存，或 provider 写入持久账本的稳定合成条目。
///
/// 常规 provider 每个源文件对应一条 FileCacheEntry，存 mtime + size + 按日按 provider 聚合的
/// records；千问办公因需跨 segment 按 request_id 去重，改为每个请求一个稳定合成 key。
public struct FileCacheEntry: Codable, Sendable, Equatable {
    /// 源文件绝对路径或稳定合成 key（同时是缓存 key）
    public let filePath: String
    /// 源文件修改时间；合成条目使用事件时间
    public let mtime: Date
    /// 源文件字节数；合成条目使用稳定的内容量
    public let size: Int
    /// 按 (provider, date) 聚合后的 token 数
    public let records: [FileDailyRecord]
    /// 按 (provider, date, session, model) 聚合后的**明细**（v0.3.33 起）。
    ///
    /// 详情页的唯一数据源。为空表示该文件由旧版本解析、或该 provider 尚未接明细
    /// —— 此时详情页会回落到「只有总量、无法展开」的降级态。
    public let details: [FileDetailRecord]

    public init(filePath: String, mtime: Date, size: Int,
                records: [FileDailyRecord], details: [FileDetailRecord] = []) {
        self.filePath = filePath
        self.mtime = mtime
        self.size = size
        self.records = records
        self.details = details
    }
}

/// 单文件内"某 provider 在某天的总 token"
public struct FileDailyRecord: Codable, Sendable, Equatable {
    /// "claude-code" / "cowork" / "qoder-cli" / "qoder-ide" / "qwen-work" / "codex" 等
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

/// 明细账本的一条：某 provider 在某天、某会话、某模型上的 5 列 token 拆分。
///
/// ## 为什么要存这个（v0.3.33 的根因改动）
///
/// v0.3.32 之前账本只存 `FileDailyRecord`（provider/date/token/cachedToken 四个字段），
/// 详情页要的净输入 / 输出 / 缓存写 / 缓存读拆分、模型名、会话名**一个都没存**，
/// 每次进详情页都由各家 DetailScanner **重新实时读一遍源日志**现算。
/// 后果就是 GitHub issue #8：源日志一旦读不到（权限问题）或被工具自己清理掉，
/// 主列表（读账本，有数）和详情页（读源文件，没数）就会打架，
/// 详情页还把 I/O 失败静默渲染成「该周期这个来源没有用量」。
///
/// 各家日志格式（Claude 的 message.usage / Codex 的 payload.info / 千问的 data.*_tokens /
/// 悟空的驼峰字段…）解析后**早就统一**成同一个 `TokenBreakdown` 了，只是用完即弃。
/// 本结构就是把那个统一结果落盘：源日志没了，明细也还在。
///
/// ## 粒度选择：会话级
///
/// 按 (provider, date, session, model) 聚合，**不是**按请求。实测本机 Claude Code
/// 13071 条请求只归成 45 个会话——会话数才是量级，请求数不是。单条约 307 字节，
/// 重度用户一年约 1 MB，相对 v0.3.32 的 0.11 MB 完全可以接受。
public struct FileDetailRecord: Codable, Sendable, Equatable {
    public let provider: String
    /// "2026-05-20" 本地日期（按 Asia/Shanghai），与 FileDailyRecord 同口径
    public let date: String
    /// 会话 ID。无会话概念的 provider（如 Cursor）填空串。
    public let sessionId: String
    /// 会话可读标题（自定义改名 > ai-title > 首条用户输入 > cwd 兜底）。
    /// 存下来是为了源日志被清理后仍显示得出会话名。
    public let title: String
    /// 日志原始 model id，不做厂商命名格式化（详情页原样展示、查价目表也用它）
    public let model: String
    /// 该会话最后活动时间（详情页「按时间」排序用）
    public let lastActivity: Date
    /// 5 列拆分：净输入 / 输出 / 缓存写 5m / 缓存写 1h / 缓存读（+ Codex 的思考）
    public let input: Int
    public let output: Int
    public let cacheCreate5m: Int
    public let cacheCreate1h: Int
    public let cacheRead: Int
    public let reasoning: Int
    /// Claude Code 专属：这条属于官方直连还是中转代理（`ClaudeSource.rawValue`）。
    /// 其它 provider 为 nil。
    public let source: String?
    /// **数据自带的金额**（WorkBuddy 的信用点 / 千问办公的积分）。
    ///
    /// 为什么必须存：这两家的金额来自日志/账单原文，**不是**按模型名查价目表算出来的
    /// （它们的模型名还被厂商打码，根本查不到）。不存下来，源日志一没金额就永久丢失。
    /// 其余 provider 为 nil —— 它们的等效美元由 `UnifiedPricing` 按模型名实时算，存了反而会
    /// 在价目表更新后变成陈旧值。
    public let nativeCost: Double?

    public init(provider: String, date: String, sessionId: String, title: String,
                model: String, lastActivity: Date, tokens: TokenBreakdown,
                source: String? = nil, nativeCost: Double? = nil) {
        self.provider = provider
        self.date = date
        self.sessionId = sessionId
        self.title = title
        self.model = model
        self.lastActivity = lastActivity
        self.input = tokens.input
        self.output = tokens.output
        self.cacheCreate5m = tokens.cacheCreate5m
        self.cacheCreate1h = tokens.cacheCreate1h
        self.cacheRead = tokens.cacheRead
        self.reasoning = tokens.reasoning
        self.source = source
        self.nativeCost = nativeCost
    }

    /// 还原成统一的 5 列结构
    public var tokens: TokenBreakdown {
        TokenBreakdown(input: input, output: output,
                       cacheCreate5m: cacheCreate5m, cacheCreate1h: cacheCreate1h,
                       cacheRead: cacheRead, reasoning: reasoning)
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
    ///
    /// **v9（v0.3.33）：账本升级为「会话级明细账本」**——`FileCacheEntry` 新增 `details`
    /// （见 `FileDetailRecord`），详情页从此读账本而非实时扫源，根治 issue #8 的
    /// 「列表有量 / 详情空」分叉。同版下架 QoderWork / 悟空两个 provider。
    ///
    /// ⚠️ **本次 bump 的代价是已知且已拍板接受的**：bump = 旧账本整份作废重扫，
    /// 只能扫回**现在还存在**的源日志。本机实测 259 条账本条目里 43 条的源日志已被
    /// 各 AI 工具自己清理/轮转掉，对应 10.7 亿 token（占总量 23.5%，主要是 6-7 月的
    /// Claude Code 用量）**永久丢失**，「累计」会从 45.7 亿掉到 35.0 亿。
    /// 决策理由：保留这批无明细的旧数据 = 账本里永远躺着一批「有总量、展不开」的特例，
    /// 那正是本次要根治的病。宁可一次性丢干净，换账本 100% 有明细、零特例。
    /// → 这件事必须在 CHANGELOG.md 的 v0.3.33 条目里写明，别让「累计」无声缩水。
    public static let currentSchemaVersion = 9

    public init(entries: [FileCacheEntry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.savedAt = Date()
        self.entries = entries
    }
}
