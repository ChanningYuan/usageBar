import Foundation
import SwiftUI
import usageBarProviders

/// 千问办公「网页令牌」这条线的 UI 镜像（v0.3.38）。
///
/// `QwenWorkBillingStore` 是 actor，SwiftUI 观察不了；协调器每轮刷新后把状态同步到这里，
/// 设置页的精确模式 chip 与详情页 Hero 的「积分未同步」提示都读它。
/// 它只描述**网页线**（今日已用 / 按会话积分）；剩余 / 每日 / 周期 / 长期走桌面线，在 `RateLimitStore` 的快照里。
@MainActor
final class QwenWorkWebSessionStatus: ObservableObject {
    static let shared = QwenWorkWebSessionStatus()

    @Published private(set) var session: QwenWorkWebSession = .off
    /// 网页令牌有效时的今日已用（详情页 Hero 之外暂无消费方，留作调试与将来扩展）
    @Published private(set) var todaySpent: Double?

    private init() {}

    func update(_ session: QwenWorkWebSession, todaySpent: Double?) {
        self.session = session
        self.todaySpent = todaySpent
    }

    /// 设置页子行 chip：文案 + 颜色档 + 主操作。
    struct Chip {
        enum Tone { case green, gray, orange }
        enum Action { case openUsagePage, reauthorize, pasteManually }
        let text: String
        let tone: Tone
        let action: (title: String, kind: Action)?
    }

    var chip: Chip {
        switch session {
        case .off:
            return Chip(text: "未开启", tone: .gray, action: nil)
        case .valid(let exp, let source):
            let tail = source == .manual ? " · 手动粘贴" : ""
            return Chip(text: "已连接 · 有效至 \(Self.shortDateTime(exp))\(tail)", tone: .green, action: nil)
        case .expired:
            return Chip(text: "网页登录已过期", tone: .orange, action: ("打开用量明细页 ›", .openUsagePage))
        case .authDenied:
            return Chip(text: "未获 Chrome 钥匙串授权", tone: .orange, action: ("重新授权 ›", .reauthorize))
        case .notFound:
            return Chip(text: "Chrome 里没有网页登录", tone: .orange, action: ("打开用量明细页 ›", .openUsagePage))
        case .noBrowser:
            return Chip(text: "没找到 Chrome", tone: .orange, action: ("手动粘贴 ›", .pasteManually))
        }
    }

    /// 详情页 Hero「积分未同步」下面那行提示：说明 + 主操作。
    var heroHint: (text: String, action: (title: String, kind: Chip.Action)?) {
        switch session {
        case .off:
            return ("精确模式已关，之后的消耗不再记录", ("去设置 ›", .reauthorize))
        case .valid:
            return ("积分同步中…", nil)
        case .expired:
            return ("网页登录已过期，之后的消耗不再记录", ("在 Chrome 打开一次用量明细页即可恢复 ›", .openUsagePage))
        case .authDenied:
            return ("未获 Chrome 钥匙串授权", ("去设置重新授权 ›", .reauthorize))
        case .notFound:
            return ("Chrome 里没有千问办公的网页登录", ("打开用量明细页登录一次 ›", .openUsagePage))
        case .noBrowser:
            return ("没找到 Chrome", ("去设置手动粘贴 ›", .pasteManually))
        }
    }

    static func shortDateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M-d HH:mm"
        return f.string(from: d)
    }
}
