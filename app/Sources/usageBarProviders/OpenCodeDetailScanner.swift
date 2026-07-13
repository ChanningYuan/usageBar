import Foundation
import usageBarCore

/// OpenCode 明细页扫描器：消息级归因 + subagent 收敛。
///
/// 与 `OpenCodeProvider` 共用 `OpenCodeDB` 读库；窗口过滤用消息自己的日界串，
/// 保证明细合计与主行完全对得上（同一套 `DailyAggregator.windowPredicate` 口径）。
public actor OpenCodeDetailScanner {
    public static let shared = OpenCodeDetailScanner()
    public init() {}

    private struct CacheSnapshot {
        let mtime: Date
        let size: Int
        let messages: [OpenCodeDB.MessageRow]
        let sessions: [String: OpenCodeDB.SessionInfo]
    }

    private var cache: CacheSnapshot?

    public func detail(window: TimeWindow, weekStartMonday: Bool = true,
                       now: Date = Date()) async -> ProviderDetail {
        let (messages, sessions) = loadAll()
        return Self.compose(messages: messages, sessions: sessions,
                            window: window, weekStartMonday: weekStartMonday, now: now)
    }

    /// 纯聚合逻辑（静态、无 IO，单测直接打）
    static func compose(messages: [OpenCodeDB.MessageRow],
                        sessions: [String: OpenCodeDB.SessionInfo],
                        window: TimeWindow, weekStartMonday: Bool, now: Date) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)
        let filtered = messages.filter { inWindow($0.date) }

        var totalTokens = TokenBreakdown()
        var totalCost = 0.0
        var bySession: [String: (tokens: TokenBreakdown, cost: Double, lastActivity: Date)] = [:]
        var byModel: [String: (tokens: TokenBreakdown, cost: Double)] = [:]

        for m in filtered {
            totalTokens.add(m.tokens)
            totalCost += m.cost

            // subagent 子会话收敛到根会话
            let root = OpenCodeDB.rootSessionId(of: m.sessionId, in: sessions)
            if var s = bySession[root] {
                s.tokens.add(m.tokens)
                s.cost += m.cost
                s.lastActivity = max(s.lastActivity, m.time)
                bySession[root] = s
            } else {
                bySession[root] = (m.tokens, m.cost, m.time)
            }

            if var mo = byModel[m.modelId] {
                mo.tokens.add(m.tokens)
                mo.cost += m.cost
                byModel[m.modelId] = mo
            } else {
                byModel[m.modelId] = (m.tokens, m.cost)
            }
        }

        let sessionRecords = bySession.map { sid, val in
            let title = sessions[sid]?.title ?? ""
            return SessionDetailRecord(
                sessionId: sid,
                title: title.isEmpty ? String(sid.prefix(12)) : title,
                subtitle: String(sid.prefix(8)),
                lastActivity: val.lastActivity,
                tokens: val.tokens,
                cost: val.cost
            )
        }.sorted { $0.tokens.total > $1.tokens.total }

        let modelRecords = byModel.map { mid, val in
            ModelDetailRecord(
                modelId: mid,
                tokens: val.tokens,
                cost: val.cost
            )
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(
            providerId: "opencode",
            windowId: window.id,
            tokens: totalTokens,
            cost: totalCost,
            models: modelRecords,
            sessions: sessionRecords
        )
    }

    private func loadAll() -> (messages: [OpenCodeDB.MessageRow], sessions: [String: OpenCodeDB.SessionInfo]) {
        let path = OpenCodeDB.dbPath
        guard let meta = OpenCodeDB.metadata(dbPath: path) else { return ([], [:]) }

        if let c = cache, c.mtime == meta.mtime, c.size == meta.size {
            return (c.messages, c.sessions)
        }

        let (messages, sessions) = OpenCodeDB.load(dbPath: path)
        cache = CacheSnapshot(mtime: meta.mtime, size: meta.size, messages: messages, sessions: sessions)
        return (messages, sessions)
    }

}
