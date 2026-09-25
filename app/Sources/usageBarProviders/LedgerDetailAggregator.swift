import Foundation
import usageBarCore

/// 从**持久明细账本**聚合详情页数据（v0.3.33 起的唯一详情数据源）。
///
/// ## 它取代了什么
///
/// v0.3.32 之前，详情页由各家 `*DetailScanner` **实时重扫源日志**现算。那套的问题是
/// 主列表读账本、详情读源文件，**两条腿走两条路**：
///   - 源日志被工具自己清理 / 轮转 → 列表还有历史数字，详情空；
///   - 源日志读不到（权限，issue #8 报告人本机 `Operation not permitted`）→ 同上，
///     且错误被 `try?` 静默吞成「该周期这个来源没有用量」，看起来像 usageBar 算错了。
///
/// 现在两边同源：provider 扫盘时把明细一并写进账本（`FileDetailRecord`），
/// 详情页从账本聚合。**不变量：列表总量 = Hero = 分模型合计 = 分会话合计**，
/// 任何时候都成立，与源文件当前是否可读无关。
///
/// ## 为什么不整个删掉各家 DetailScanner
///
/// 它们仍负责**解析**（把各家日志格式翻译成统一的 `TokenBreakdown` + 会话/模型归属）。
/// 变的只是「解析结果去哪」：以前直接渲染、用完即弃，现在落进账本再渲染。
/// 联网类 provider（Cursor / 千问办公积分）另有自己的缓存，不走这里。
public enum LedgerDetailAggregator {

    /// 按窗口聚合某 provider 的明细账本。
    ///
    /// - Parameters:
    ///   - details: 该 provider 的全部明细条目（跨文件、跨日期）
    ///   - costUnavailable: 该 provider 的模型名查不到价（如 Qoder CLI 全是打码别名），
    ///     此时不算等效美元，`cost` 恒 0、展示层显示「无价目」
    public static func aggregate(providerId: String,
                                 details: [FileDetailRecord],
                                 window: TimeWindow,
                                 weekStartMonday: Bool = true,
                                 now: Date = Date(),
                                 costUnavailable: Bool = false) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        var hero = TokenBreakdown()
        var heroCost = 0.0
        var bySource: [ClaudeSource: TokenBreakdown] = [:]
        var sourceCost: [ClaudeSource: Double] = [:]
        var byModel: [String: TokenBreakdown] = [:]
        var modelCost: [String: Double] = [:]
        var bySession: [String: TokenBreakdown] = [:]
        var sessionCost: [String: Double] = [:]
        // 会话标题 / 最后活动：同一会话可能跨多天多条，取最近一条的标题、最晚的活动时间
        var sessionTitle: [String: (title: String, at: Date)] = [:]
        var sessionLastActivity: [String: Date] = [:]

        for d in details where d.provider == providerId && inWindow(d.date) {
            let tb = d.tokens
            // 金额三档：① 数据自带（WorkBuddy 信用点 / 千问办公积分）直接用；
            // ② 模型名查得到价 → 按价目表算等效美元；③ 打码模型名 → 无价目，恒 0。
            let c = d.nativeCost ?? (costUnavailable ? 0 : UnifiedPricing.cost(tb, modelId: d.model))

            hero.add(tb); heroCost += c
            byModel[d.model, default: TokenBreakdown()].add(tb)
            modelCost[d.model, default: 0] += c

            if let raw = d.source, let src = ClaudeSource(rawValue: raw) {
                bySource[src, default: TokenBreakdown()].add(tb)
                sourceCost[src, default: 0] += c
            }

            // sessionId 为空表示该 provider 无会话概念（Cursor 等）→ 不进「按会话」
            guard !d.sessionId.isEmpty else { continue }
            bySession[d.sessionId, default: TokenBreakdown()].add(tb)
            sessionCost[d.sessionId, default: 0] += c
            let prev = sessionLastActivity[d.sessionId] ?? .distantPast
            sessionLastActivity[d.sessionId] = max(prev, d.lastActivity)
            // 标题取「活动时间最新」那条——会话改名后以最后一次为准
            if !d.title.isEmpty, (sessionTitle[d.sessionId]?.at ?? .distantPast) <= d.lastActivity {
                sessionTitle[d.sessionId] = (d.title, d.lastActivity)
            }
        }

        let sources = ClaudeSource.allCases.compactMap { source -> SourceDetailRecord? in
            guard let tb = bySource[source], tb.total > 0 else { return nil }
            return SourceDetailRecord(source: source, tokens: tb, cost: sourceCost[source] ?? 0)
        }

        // token 相同再按金额排（v0.3.45）：豆包工作这类只有积分、token 恒 0 的来源，
        // 只按 token 排就是字典的随机序，每次进详情页顺序都不一样
        let models = byModel.map { (mid, tb) in
            ModelDetailRecord(modelId: mid, tokens: tb, cost: modelCost[mid] ?? 0)
        }.sorted { ($0.tokens.total, $0.cost) > ($1.tokens.total, $1.cost) }

        let sessions = bySession.map { (sid, tb) -> SessionDetailRecord in
            SessionDetailRecord(sessionId: sid,
                                title: sessionTitle[sid]?.title ?? "(无标题会话)",
                                subtitle: String(sid.prefix(8)),
                                lastActivity: sessionLastActivity[sid] ?? .distantPast,
                                tokens: tb, cost: sessionCost[sid] ?? 0)
        }.sorted { ($0.tokens.total, $0.cost) > ($1.tokens.total, $1.cost) }

        return ProviderDetail(providerId: providerId, windowId: window.id,
                              tokens: hero, cost: heroCost, sources: sources,
                              models: models, sessions: sessions)
    }
}
