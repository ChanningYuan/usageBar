import Foundation

/// 一个 session / model 的 5 列 token 拆分（精确计费用）。
///
/// 5 列取自 Claude transcript 的 `message.usage`：
///   - input  = `input_tokens`（净输入）
///   - output = `output_tokens`
///   - cacheCreate5m / 1h = `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`
///   - cacheRead = `cache_read_input_tokens`（命中读取）
///
/// 拆 5m / 1h 是因为缓存写入两档倍率不同（1.25× / 2×，见 `ClaudePricing`），合一算会不准。
///
/// **Codex 复用同一结构（字段语义映射）**：Codex 无缓存写 / 无 5m-1h 拆分，四维口径为
///   - `input`     = `input_tokens − cached_input_tokens`（净输入，真正新喂进去的）
///   - `cacheRead` = `cached_input_tokens`（缓存命中读，input 的子集）
///   - `output`    = `output_tokens`（含 reasoning）
///   - `reasoning` = `reasoning_output_tokens`（思考，output 的子集，**不计入 total**）
///   - `cacheCreate5m / 1h` 恒 0
///  这样 `total = input + output + cacheRead = input_tokens + output_tokens`，与 Codex 口径自洽。
public struct TokenBreakdown: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheCreate5m: Int
    public var cacheCreate1h: Int
    public var cacheRead: Int
    /// 思考 token（Codex `reasoning_output_tokens`，output 的子集）。Claude 恒 0。**不计入 `total`**。
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0,
                cacheCreate5m: Int = 0, cacheCreate1h: Int = 0, cacheRead: Int = 0,
                reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreate5m = cacheCreate5m
        self.cacheCreate1h = cacheCreate1h
        self.cacheRead = cacheRead
        self.reasoning = reasoning
    }

    /// 缓存写入合计（5m + 1h），展示层「缓存写」一格用。
    public var cacheCreate: Int { cacheCreate5m + cacheCreate1h }

    /// 总 token（与主进度条口径一致：input + output + cacheCreate + cacheRead）。
    public var total: Int { input + output + cacheCreate5m + cacheCreate1h + cacheRead }

    /// 缓存命中读取分量（= cacheRead，进度条浅色段口径）。
    public var cached: Int { cacheRead }

    /// 缓存命中率（与主行「% 缓存命中」口径一致：cached / total）。
    public var hitRate: Double {
        total > 0 ? Double(cached) / Double(total) : 0
    }

    public mutating func add(_ o: TokenBreakdown) {
        input += o.input
        output += o.output
        cacheCreate5m += o.cacheCreate5m
        cacheCreate1h += o.cacheCreate1h
        cacheRead += o.cacheRead
        reasoning += o.reasoning
    }

    public static func + (a: TokenBreakdown, b: TokenBreakdown) -> TokenBreakdown {
        var r = a; r.add(b); return r
    }
}

/// 分会话明细行（详情页「按会话」列表一行）。
public struct SessionDetailRecord: Sendable, Equatable, Identifiable {
    public let sessionId: String
    /// 可读标题：ai-title → 首条用户输入 → cwd 目录名 兜底
    public let title: String
    /// 副标题 = sessionId 前 8 位
    public let subtitle: String
    /// 最后活动时间（按时间排序用）
    public let lastActivity: Date
    public let tokens: TokenBreakdown
    /// ≈$ 等效 API 花费
    public let cost: Double

    public var id: String { sessionId }

    public init(sessionId: String, title: String, subtitle: String,
                lastActivity: Date, tokens: TokenBreakdown, cost: Double) {
        self.sessionId = sessionId
        self.title = title
        self.subtitle = subtitle
        self.lastActivity = lastActivity
        self.tokens = tokens
        self.cost = cost
    }
}

/// 分模型明细行（详情页「按模型」列表一行）。
public struct ModelDetailRecord: Sendable, Equatable, Identifiable {
    /// 日志原始 model id；详情页原样展示，不做厂商命名格式化。
    public let modelId: String
    public let tokens: TokenBreakdown
    public let cost: Double

    public var id: String { modelId }
    public var hitRate: Double { tokens.hitRate }

    public init(modelId: String, tokens: TokenBreakdown, cost: Double) {
        self.modelId = modelId
        self.tokens = tokens
        self.cost = cost
    }
}

/// 分来源明细行（Claude Code 详情页「按来源」列表一行）。
public struct SourceDetailRecord: Sendable, Equatable, Identifiable {
    public let source: ClaudeSource
    public let tokens: TokenBreakdown
    public let cost: Double

    public var id: String { source.rawValue }
    public var hitRate: Double { tokens.hitRate }

    public init(source: ClaudeSource, tokens: TokenBreakdown, cost: Double) {
        self.source = source
        self.tokens = tokens
        self.cost = cost
    }
}

/// 某 provider 在某窗口的完整明细（drill-in 详情页的唯一数据源）。
public struct ProviderDetail: Sendable, Equatable {
    public let providerId: String
    /// 窗口 id（"today" / "thisWeek" / ...），与当前选中周期一致
    public let windowId: String
    /// Hero 合计
    public let tokens: TokenBreakdown
    /// ≈$ 等效 API 花费合计
    public let cost: Double
    /// 金额数据是否已成功取得。默认 true；用于区分“真实为 0”和“尚未同步”（千问办公积分）。
    public let costAvailable: Bool
    /// 分来源（固定顺序：官方直连 → 中转/代理；无流量来源不输出）
    public let sources: [SourceDetailRecord]
    /// 分模型（token 降序），已过滤 `<synthetic>`
    public let models: [ModelDetailRecord]
    /// 分会话（默认 token 降序；UI 可切时间序）
    public let sessions: [SessionDetailRecord]

    public var hitRate: Double { tokens.hitRate }
    public var sourceCount: Int { sources.count }
    public var modelCount: Int { models.count }
    public var sessionCount: Int { sessions.count }

    public init(providerId: String, windowId: String, tokens: TokenBreakdown,
                cost: Double, costAvailable: Bool = true,
                sources: [SourceDetailRecord] = [],
                models: [ModelDetailRecord], sessions: [SessionDetailRecord]) {
        self.providerId = providerId
        self.windowId = windowId
        self.tokens = tokens
        self.cost = cost
        self.costAvailable = costAvailable
        self.sources = sources
        self.models = models
        self.sessions = sessions
    }

    public static func empty(providerId: String, windowId: String) -> ProviderDetail {
        ProviderDetail(providerId: providerId, windowId: windowId,
                       tokens: TokenBreakdown(), cost: 0, models: [], sessions: [])
    }
}
