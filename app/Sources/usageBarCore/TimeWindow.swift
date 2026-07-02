import Foundation

/// 查询窗口。对应 token-stats command 的 today/week/all/custom。
public enum TimeWindow: Hashable, Sendable {
    /// 本机时区 00:00 到现在
    case today
    /// 本周（日历对齐，起始日可配 周一/周日）
    case thisWeek
    /// 滚动 7 天
    case last7Days
    /// 本月（日历对齐，1 号 00:00 起）
    case thisMonth
    /// 滚动 30 天
    case last30Days
    /// 全量
    case all
    /// 自定义闭区间
    case custom(ClosedRange<Date>)

    // 注:窗口的实际切片逻辑不在这里,而在 `DailyAggregator.aggregate`(按 Asia/Shanghai
    // 日界字符串比较:今日 = date==today,近 7 天 = 含今天共 7 个日历日)。本枚举只负责
    // UI 选择(.id / .displayName / 各 case)。早期的 dateRange/contains(滚动 168h/720h
    // 秒级窗口)跟实际聚合语义不一致且从无调用,已删除,避免误导维护者。

    public var displayName: String {
        switch self {
        case .today: return "今日"
        case .thisWeek: return "本周"
        case .last7Days: return "近 7 天"
        case .thisMonth: return "本月"
        case .last30Days: return "近 30 天"
        case .all: return "全量"
        case .custom(let r):
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            return "\(f.string(from: r.lowerBound)) ~ \(f.string(from: r.upperBound))"
        }
    }
}
