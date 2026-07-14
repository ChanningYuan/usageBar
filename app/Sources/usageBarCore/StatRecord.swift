import Foundation

/// 扁平的 (provider, time, token) 三元组 —— UI 用的最终缓存
///
/// 整个 statsCache 就是 `[StatRecord]`，4 窗口 × 5 provider = 20 条记录。
///
/// 切窗口纯走 filter：`allStats.filter { $0.time == "today" }`
public struct StatRecord: Codable, Sendable, Equatable {
    /// "claude-code" / "cowork" / "qoder-cli" / "qoder-work" / "qoder-ide" / "codex" / "wukong"
    public let provider: String
    /// "today" / "last7Days" / "last30Days" / "all"
    public let time: String
    /// 总 token 数
    public let token: Int
    /// token 里「缓存命中读取」的分量（双色进度条浅色段 + 悬浮气泡用）；无缓存 provider 为 0
    public let cachedToken: Int

    public init(provider: String, time: String, token: Int, cachedToken: Int = 0) {
        self.provider = provider
        self.time = time
        self.token = token
        self.cachedToken = cachedToken
    }
}

/// TimeWindow → time 字符串（统一映射，避免拼错）
public extension TimeWindow {
    var id: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "thisWeek"
        case .last7Days: return "last7Days"
        case .thisMonth: return "thisMonth"
        case .last30Days: return "last30Days"
        case .all: return "all"
        case .custom: return "custom"
        }
    }

    /// 所有需要预加载到缓存的窗口
    static let cachedWindows: [TimeWindow] = [.today, .yesterday, .thisWeek, .last7Days, .thisMonth, .last30Days, .all]
}
