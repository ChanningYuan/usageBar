import Foundation
import usageBarCore

/// 时间 tab 的共享解析 —— 列表头（`UsageView`）与详情页周期切换器（`ProviderDetailView`）
/// 共用同一份「勾选顺序 → 窗口序列」和「窗口 → 短标签」逻辑，避免两处分叉。

extension TabSettings {
    /// 按用户配置的 tab 顺序 ∩ 有效性解析出要渲染的窗口序列（custom 需区间有效）。
    var orderedWindows: [TimeWindow] {
        tabOrder.compactMap { id in
            switch id {
            case "today": return .today
            case "thisWeek": return .thisWeek
            case "last7Days": return .last7Days
            case "thisMonth": return .thisMonth
            case "last30Days": return .last30Days
            case "all": return .all
            case "custom": return customRange.map { TimeWindow.custom($0) }
            default: return nil
            }
        }
    }
}

extension TimeWindow {
    /// tab 短标签（今日 / 本周 / 7天 / 本月 / 30天 / 累计 / 自定义区间）。
    var tabLabel: String {
        switch self {
        case .today: return "今日"
        case .thisWeek: return "本周"
        case .last7Days: return "7天"
        case .thisMonth: return "本月"
        case .last30Days: return "30天"
        case .all: return "累计"
        case .custom(let r): return TimeWindow.shortRangeLabel(r)
        }
    }

    /// 自定义区间短标签：同月 `6/1–15`、跨月 `6/28–7/3`
    static func shortRangeLabel(_ r: ClosedRange<Date>) -> String {
        let cal = Calendar.current
        let lo = cal.dateComponents([.month, .day], from: r.lowerBound)
        let hi = cal.dateComponents([.month, .day], from: r.upperBound)
        if lo.month == hi.month {
            return "\(lo.month ?? 0)/\(lo.day ?? 0)–\(hi.day ?? 0)"
        }
        return "\(lo.month ?? 0)/\(lo.day ?? 0)–\(hi.month ?? 0)/\(hi.day ?? 0)"
    }
}
