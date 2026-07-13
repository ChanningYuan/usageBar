import Foundation
import usageBarCore

/// 悟空明细扫描器（v0.3.22 新增）——**双源合并**。
///
/// ## 为什么必须合并双源（2026-07-13 探针实测，推翻了立项时的假设）
///
/// 立项时以为旧源只是「0.9.66 之前的一点冻结历史」，缺口很小，于是定了「不补行、允许分项之和
/// 小于主行」（拍板 4b）。**实测后发现完全相反**：
///
/// | 源 | token | 占比 |
/// |---|---|---|
/// | 源 A · 旧 `requests.jsonl`（冻结） | **351,855,804** | **99.96%** |
/// | 源 B · 新 codex rollout | 149,414 | 0.04% |
///
/// 只做源 B 的话，详情页会显示 **14.9 万**，而列表主行显示 **3.52 亿** —— 那不是"略有出入"，
/// 是页面彻底崩坏。**而且旧源完全拆得开**：字段里有 `model`（多为真名：`claude-opus-4-7` /
/// `gpt-5.5` / `deepseek-v4-flash`，价目表都查得到）和 `sessionId`。
/// → 所以不是"允许对不上"，是**必须把旧源接进来**。实测数据存档：
/// `_notes/docs/0713-Cursor计数修复与详情页扩展/探针实测-悟空与QoderCLI.json`
///
/// ## 两源口径（与 `WukongProvider` 主行逐字对齐，否则明细之和对不上主行）
/// - **源 A**（`~/Library/.../dingtalk-rewind-server/users/*/storage/llm_proxy/requests.jsonl`）：
///   token 顶层平铺，`total = promptTokens + completionTokens`，`cacheTokens` 是 promptTokens 的**子集**
///   → 净输入 = `promptTokens − cacheTokens`，缓存读 = `cacheTokens`，输出 = `completionTokens`，无缓存写/思考。
///   ⚠️ `cacheTokens` 是 2026-05-18 才加的字段，更早的记录整个 key 缺失 → `?? 0` 兜底。
/// - **源 B**（`~/.real/**/kernel/codex/sessions/rollout-*.jsonl`）：与 Codex CLI **完全同款**，
///   `total_token_usage` 是**累计值 → 必须差分**。直接复用 `CodexDetailScanner`（同一套 baseline+峰值差分），
///   不重写算法。
///
/// 两源不重叠、零双算（升级前后各管一段，实测交集为空），故直接相加。
public actor WukongDetailScanner {
    public static let shared = WukongDetailScanner()
    public init() {}

    struct LegacyRow {
        let date: String
        let sessionId: String
        let model: String
        let tokens: TokenBreakdown
        let time: Date
    }

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let rows: [LegacyRow]
    }

    private var cache: [String: CacheEntry] = [:]

    private var legacyBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dingtalk-rewind-server/users")
    }
    private var rolloutRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".real")
    }

    public func detail(window: TimeWindow, weekStartMonday: Bool = true,
                       now: Date = Date()) async -> ProviderDetail {
        // 源 B：复用 Codex 的差分算法（格式完全同款），只换根目录
        let fromRollout = await CodexDetailScanner.shared.detail(
            providerId: "wukong", root: rolloutRoot,
            requirePath: "/kernel/codex/sessions/",
            window: window, weekStartMonday: weekStartMonday, now: now)

        // 源 A：旧 requests.jsonl
        let legacy = Self.compose(rows: loadLegacy(), window: window,
                                  weekStartMonday: weekStartMonday, now: now)

        return Self.merge(legacy, fromRollout, windowId: window.id)
    }

    /// 两源相加。models / sessions 按 key 合并（两源的 key 空间不重叠，但仍按 key 归并以防万一）。
    static func merge(_ a: ProviderDetail, _ b: ProviderDetail, windowId: String) -> ProviderDetail {
        var tokens = a.tokens; tokens.add(b.tokens)

        var byModel: [String: (tb: TokenBreakdown, cost: Double)] = [:]
        for m in a.models + b.models {
            var cur = byModel[m.modelId] ?? (TokenBreakdown(), 0)
            cur.tb.add(m.tokens); cur.cost += m.cost
            byModel[m.modelId] = cur
        }

        var bySession: [String: SessionDetailRecord] = [:]
        for s in a.sessions + b.sessions {
            if let cur = bySession[s.sessionId] {
                var tb = cur.tokens; tb.add(s.tokens)
                bySession[s.sessionId] = SessionDetailRecord(
                    sessionId: s.sessionId, title: cur.title, subtitle: cur.subtitle,
                    lastActivity: max(cur.lastActivity, s.lastActivity),
                    tokens: tb, cost: cur.cost + s.cost)
            } else {
                bySession[s.sessionId] = s
            }
        }

        return ProviderDetail(
            providerId: "wukong", windowId: windowId,
            tokens: tokens, cost: a.cost + b.cost,
            models: byModel.map { ModelDetailRecord(modelId: $0.key, tokens: $0.value.tb, cost: $0.value.cost) }
                .sorted { $0.tokens.total > $1.tokens.total },
            sessions: bySession.values.sorted { $0.tokens.total > $1.tokens.total })
    }

    /// 源 A 的纯聚合（静态、无 IO，单测直接打）
    static func compose(rows: [LegacyRow], window: TimeWindow,
                        weekStartMonday: Bool, now: Date) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        var total = TokenBreakdown()
        var totalCost = 0.0
        var byModel: [String: TokenBreakdown] = [:]
        var bySession: [String: (tb: TokenBreakdown, last: Date)] = [:]

        for r in rows where inWindow(r.date) {
            total.add(r.tokens)
            byModel[r.model, default: TokenBreakdown()].add(r.tokens)
            var s = bySession[r.sessionId] ?? (TokenBreakdown(), r.time)
            s.tb.add(r.tokens); s.last = max(s.last, r.time)
            bySession[r.sessionId] = s
        }

        let models = byModel.map { mid, tb -> ModelDetailRecord in
            let c = UnifiedPricing.cost(tb, modelId: mid)
            totalCost += c
            return ModelDetailRecord(modelId: mid, tokens: tb, cost: c)
        }

        // 会话花费按其模型构成逐一算不现实（一个会话可能跨模型）→ 用该会话 token 占比摊到总花费。
        // 与 Codex/Claude 侧的做法一致（那边是逐 unit 算好再汇总，这里旧源没有模型×会话的交叉维度）。
        let sessions = bySession.map { sid, v -> SessionDetailRecord in
            let share = total.total > 0 ? Double(v.tb.total) / Double(total.total) : 0
            return SessionDetailRecord(
                sessionId: sid, title: String(sid.prefix(12)), subtitle: String(sid.prefix(8)),
                lastActivity: v.last, tokens: v.tb, cost: totalCost * share)
        }

        return ProviderDetail(providerId: "wukong", windowId: window.id,
                              tokens: total, cost: totalCost,
                              models: models, sessions: sessions)
    }

    // MARK: - 源 A 读盘（按文件 mtime 缓存）

    private func loadLegacy() -> [LegacyRow] {
        guard FileManager.default.fileExists(atPath: legacyBase.path) else { return [] }
        let files = JSONLReader.findFiles(under: legacyBase) { url in
            url.lastPathComponent == "requests.jsonl" && url.path.contains("/storage/llm_proxy/")
        }
        var all: [LegacyRow] = []
        for url in files {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }
            if let c = cache[path], c.mtime == meta.mtime, c.size == meta.size {
                all.append(contentsOf: c.rows); continue
            }
            let rows = Self.parseLegacy(url: url)
            cache[path] = CacheEntry(mtime: meta.mtime, size: meta.size, rows: rows)
            all.append(contentsOf: rows)
        }
        return all
    }

    static func parseLegacy(url: URL) -> [LegacyRow] {
        var rows: [LegacyRow] = []
        try? JSONLReader.forEachLine(at: url) { obj in
            // 时间戳：epoch 毫秒
            let ms: Double
            if let i = obj["createdAtMs"] as? Int { ms = Double(i) }
            else if let d = obj["createdAtMs"] as? Double { ms = d }
            else { return }
            guard ms > 0 else { return }
            let ts = Date(timeIntervalSince1970: ms / 1000.0)

            let prompt = (obj["promptTokens"] as? Int) ?? 0
            let completion = (obj["completionTokens"] as? Int) ?? 0
            if prompt + completion == 0 { return }   // 0.9.66 后的 codex stub 行 token 全 0，自动滤掉

            // cacheTokens 是 promptTokens 的子集（2026-05-18 才加的字段，更早的记录缺失 → 0）
            let cached = min((obj["cacheTokens"] as? Int) ?? 0, prompt)

            let tb = TokenBreakdown(input: prompt - cached, output: completion,
                                    cacheCreate5m: 0, cacheCreate1h: 0, cacheRead: cached)

            let model = (obj["model"] as? String) ?? ""
            // sessionId 覆盖率不是 100%（实测 8429 行里只有 261 个不同值）→ 退回 traceId，再退回未知
            let sid = (obj["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (obj["traceId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "(未知会话)"

            rows.append(LegacyRow(date: DailyAggregator.dateString(for: ts),
                                  sessionId: sid,
                                  model: model.isEmpty ? "(未知)" : model,
                                  tokens: tb, time: ts))
        }
        return rows
    }
}
