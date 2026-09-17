import Foundation
import usageBarCore

/// Codex 详情懒加载扫描器（drill-in 展开分会话 / 分模型时才跑，独立于主刷新快路径）。
///
/// 数据源 `~/.codex/sessions/**/rollout-*.jsonl` + 同级 `archived_sessions/`（v0.3.40 起含归档对话，
/// 枚举与去重走 `CodexRolloutFiles`，与主行同一份文件清单）。与主行 `CodexProvider` 同源、同一套差分状态机
/// （`CodexLineage`：峰值门 / min(last,增幅) / 继承快照不计 / 重启从头计 / 乱序跳过），
/// 但按 (model, session, date) 聚出四维 token（净输入 / 缓存命中 / 输出 / 思考）。
///
/// ── 与 Claude 扫描器的关键差异 ──
///  1. Codex 的 `token_count` 事件给的是**会话累计**（`total_token_usage`），需差分求增量；
///     差分**必须**走 `CodexLineage`，别在这里另写一套——两套口径一分叉，「列表总量 = 详情合计」就破了。
///  2. model 不在 token_count 里、而在 `turn_context.payload.model`；按出现顺序跟踪「当前模型」再归账。
///  3. 无 ai-title：标题取首条 `event_msg/user_message`（跳过 `<...>` 环境注入块），兜底 cwd 目录名。
///  4. fork：`session_meta.forked_from_id` 存在时用父会话 final 作差分基线（同 `CodexProvider` 信号1）。
///
/// 带按文件 mtime 的内存缓存（缓存的是「原始事件 + meta」，窗口无关）；差分 / 归窗在 `detail()` 里做，
/// 因为 fork 基线依赖跨文件的处理顺序。
public actor CodexDetailScanner {
    public static let shared = CodexDetailScanner()
    public init() {}

    /// 一条 token_count：累计 `total_token_usage` + 单次 `last_token_usage`（可能缺）+ 当时模型。
    private typealias Ev = CodexTokenEvent

    private struct Meta {
        let ownId: String
        let forkedFromId: String?
        let isSubagent: Bool
        let title: String?      // 首条 user_message
        let cwd: String?
        let firstModel: String
        let lastActivity: Date
    }

    private struct FileParse {
        let events: [Ev]
        let meta: Meta
    }

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let parse: FileParse
    }

    private var cache: [String: CacheEntry] = [:]

    // MARK: - 对外入口

    /// 扫描并聚合 Codex（或同款 rollout 格式的 provider）在某窗口的明细。
    ///
    /// ⚠️ `root` / `requirePath` 由调用方传入（v0.3.22 起）。此前路径写死 `~/.codex/sessions`，
    /// 参数化后同一套差分算法可被同款 rollout 格式的 provider 共用。
    public func detail(providerId: String, root: URL, requirePath: String? = nil,
                       window: TimeWindow,
                       weekStartMonday: Bool = true, now: Date = Date()) async -> ProviderDetail {
        // 文件名 `rollout-{ISO时间}-{uuid}` 字典序 == 时间序 → 父会话一定排在它的 fork 之前。
        let files = allFiles(root: root, requirePath: requirePath)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)
        let threadNames = loadThreadNames(sessionsDir: root)   // sessionId → Codex 侧栏标题

        var sessionFinal: [String: CodexUsage] = [:]   // ownId → 历史最大累计（fork baseline 用）
        var hero = TokenBreakdown(); var heroCost = 0.0
        var byModel: [String: TokenBreakdown] = [:]; var modelCost: [String: Double] = [:]
        var bySession: [String: TokenBreakdown] = [:]; var sessionCost: [String: Double] = [:]
        var sessMeta: [String: Meta] = [:]

        for url in files {
            let path = url.path
            guard let m = FileMetadata.read(at: path) else { continue }

            let fp: FileParse
            if let c = cache[path], c.mtime == m.mtime, c.size == m.size {
                fp = c.parse
            } else {
                guard let parsed = parse(url: url) else { continue }
                cache[path] = CacheEntry(mtime: m.mtime, size: m.size, parse: parsed)
                fp = parsed
            }
            let meta = fp.meta
            let sid = meta.ownId.isEmpty ? path : meta.ownId

            let (deltas, maxTotal) = Self.lineage(fp, sessionFinal: sessionFinal)
            for d in deltas {
                let date = DailyAggregator.dateString(for: d.ts)
                guard inWindow(date) else { continue }
                let tb = Self.breakdown(d.delta)
                let model = d.model.isEmpty ? meta.firstModel : d.model
                let c = UnifiedPricing.cost(tb, modelId: model)
                hero.add(tb); heroCost += c
                byModel[model, default: TokenBreakdown()].add(tb); modelCost[model, default: 0] += c
                bySession[sid, default: TokenBreakdown()].add(tb); sessionCost[sid, default: 0] += c
            }

            if !meta.ownId.isEmpty {
                sessionFinal[meta.ownId] = (sessionFinal[meta.ownId] ?? .zero).componentMax(maxTotal)
            }
            if let existing = sessMeta[sid] {
                sessMeta[sid] = Meta(ownId: existing.ownId, forkedFromId: existing.forkedFromId,
                                     isSubagent: existing.isSubagent,
                                     title: existing.title ?? meta.title,
                                     cwd: existing.cwd ?? meta.cwd,
                                     firstModel: existing.firstModel.isEmpty ? meta.firstModel : existing.firstModel,
                                     lastActivity: max(existing.lastActivity, meta.lastActivity))
            } else {
                sessMeta[sid] = meta
            }
        }

        let models = byModel.map { (mid, tb) in
            ModelDetailRecord(modelId: mid, tokens: tb, cost: modelCost[mid] ?? 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        let sessions = bySession.map { (sid, tb) -> SessionDetailRecord in
            let mt = sessMeta[sid]
            // 标题优先级：Codex 侧栏正经标题（session_index）> 首条真实用户消息 > cwd 目录名。
            let title = threadNames[sid]
                ?? mt?.title
                ?? mt?.cwd.map { ($0 as NSString).lastPathComponent }
                ?? "(无标题会话)"
            return SessionDetailRecord(sessionId: sid, title: title,
                                       subtitle: String(sid.prefix(8)),
                                       lastActivity: mt?.lastActivity ?? .distantPast,
                                       tokens: tb, cost: sessionCost[sid] ?? 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(providerId: providerId, windowId: window.id,
                              tokens: hero, cost: heroCost, models: models, sessions: sessions)
    }

    /// 数据可能已变（主刷新后）→ 清缓存，下次重扫。
    public func invalidate() { cache.removeAll() }

    /// 全量扫描并产出**写进持久账本的明细条目**（v0.3.33，issue #8）。
    ///
    /// ⚠️ **不能像 Claude 系那样按单文件独立产明细**：Codex 的 `fork` 会把父会话整段 token
    /// replay 进新文件，必须拿父会话的 final 当差分基线（见 `CodexProvider` 文件头的
    /// 「fork / resume 跨文件去重」段）。基线是**跨文件**状态，逐文件各算各的会把 replay 段
    /// 重复计成新增（同事机实测 2~2.5 倍虚高）。所以这里整体扫一遍、按文件名时间序处理，
    /// 与主行口径逐字一致。
    public func allDetails(providerId: String, root: URL,
                           requirePath: String? = nil) async -> [FileDetailRecord] {
        let files = allFiles(root: root, requirePath: requirePath)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let threadNames = loadThreadNames(sessionsDir: root)

        var sessionFinal: [String: CodexUsage] = [:]
        var acc: [String: TokenBreakdown] = [:]        // key = session|model|date
        var sessMeta: [String: Meta] = [:]
        var lastAt: [String: Date] = [:]

        for url in files {
            let path = url.path
            guard let m = FileMetadata.read(at: path) else { continue }

            let fp: FileParse
            if let c = cache[path], c.mtime == m.mtime, c.size == m.size {
                fp = c.parse
            } else {
                guard let parsed = parse(url: url) else { continue }
                cache[path] = CacheEntry(mtime: m.mtime, size: m.size, parse: parsed)
                fp = parsed
            }
            let meta = fp.meta
            let sid = meta.ownId.isEmpty ? path : meta.ownId

            let (deltas, maxTotal) = Self.lineage(fp, sessionFinal: sessionFinal)
            for d in deltas {
                let date = DailyAggregator.dateString(for: d.ts)
                let model = d.model.isEmpty ? meta.firstModel : d.model
                acc["\(sid)\u{0}\(model)\u{0}\(date)", default: TokenBreakdown()].add(Self.breakdown(d.delta))
                lastAt[sid] = max(lastAt[sid] ?? .distantPast, d.ts)
            }

            if !meta.ownId.isEmpty {
                sessionFinal[meta.ownId] = (sessionFinal[meta.ownId] ?? .zero).componentMax(maxTotal)
            }
            if let existing = sessMeta[sid] {
                sessMeta[sid] = Meta(ownId: existing.ownId, forkedFromId: existing.forkedFromId,
                                     isSubagent: existing.isSubagent,
                                     title: existing.title ?? meta.title,
                                     cwd: existing.cwd ?? meta.cwd,
                                     firstModel: existing.firstModel.isEmpty ? meta.firstModel : existing.firstModel,
                                     lastActivity: max(existing.lastActivity, meta.lastActivity))
            } else {
                sessMeta[sid] = meta
            }
        }

        return acc.map { (key, tb) in
            let parts = key.components(separatedBy: "\u{0}")
            let sid = parts[0], model = parts[1], date = parts[2]
            let mt = sessMeta[sid]
            let title = threadNames[sid] ?? mt?.title
                ?? mt?.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
            return FileDetailRecord(provider: providerId, date: date, sessionId: sid,
                                    title: title, model: model,
                                    lastActivity: lastAt[sid] ?? mt?.lastActivity ?? .distantPast,
                                    tokens: tb)
        }
    }

    // MARK: - 差分（与 CodexProvider 同一状态机）

    /// baseline 决策（同 CodexProvider）：subagent 短路 > fork 信号1 > 默认 0，然后交给 `CodexLineage`。
    /// 返回 (真实增量, 历史最大累计)；后者写回 `sessionFinal` 给后续 fork 当基线。
    private static func lineage(_ fp: FileParse, sessionFinal: [String: CodexUsage])
        -> (deltas: [CodexDeltaEvent], maxTotal: CodexUsage) {
        var baseline = CodexUsage.zero
        if !fp.meta.isSubagent, let parent = fp.meta.forkedFromId, let pf = sessionFinal[parent] {
            baseline = pf
        }
        let r = CodexLineage.deltas(events: fp.events, baseline: baseline)
        return (r.deltas.filter { $0.delta.total > 0 }, r.maxTotal)
    }

    /// 四维增量 → 统一 5 列：净输入 = input − cached；缓存读 = cached；思考 ≤ 输出。
    /// 恒等式 net + cacheRead + output == delta.total，与主行 `FileDailyRecord.token` 逐事件相等。
    private static func breakdown(_ d: CodexUsage) -> TokenBreakdown {
        TokenBreakdown(input: max(0, d.input - d.cached), output: d.output,
                       cacheRead: min(d.cached, d.input), reasoning: min(d.reasoning, d.output))
    }

    // MARK: - 文件枚举（与 CodexProvider 同一份清单）

    /// `root`（sessions 目录）+ 同级 `archived_sessions/`，按文件名去重。
    /// ⚠️ 必须与主行同一份清单：主行扫了归档、明细没扫，「列表总量 = 详情合计」立刻不成立。
    private func allFiles(root: URL, requirePath: String?) -> [URL] {
        CodexRolloutFiles.list(sessionsDir: root, requirePath: requirePath).map(\.url)
    }

    /// Codex 会话正经标题源：`~/.codex/session_index.jsonl`（每行 `{id, thread_name, updated_at}`，
    /// 与 Codex Desktop 侧栏同一份）。返回 sessionId → thread_name。每次 `detail()` 现读、始终最新。
    private func loadThreadNames(sessionsDir: URL) -> [String: String] {
        let url = sessionsDir.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var map: [String: String] = [:]
        try? JSONLReader.forEachLine(at: url) { obj in
            if let id = obj["id"] as? String,
               let name = (obj["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                map[id] = name
            }
        }
        return map
    }

    // MARK: - 单文件解析（窗口无关；只收原始事件 + meta）

    private func parse(url: URL) -> FileParse? {
        var events: [Ev] = []
        var ownId = ""; var forkedFrom: String? = nil; var isSub = false
        var title: String? = nil; var cwd: String? = nil
        var currentModel = ""; var firstModel = ""
        var lastTs = Date.distantPast

        try? JSONLReader.forEachLine(at: url) { obj in
            guard let type = obj["type"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { return }
            switch type {
            case "session_meta":
                if ownId.isEmpty {
                    ownId = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? ""
                }
                if forkedFrom == nil { forkedFrom = payload["forked_from_id"] as? String }
                if (payload["source"] as? [String: Any])?["subagent"] != nil { isSub = true }
                cwd = cwd ?? (payload["cwd"] as? String)

            case "turn_context":
                if let mdl = payload["model"] as? String, !mdl.isEmpty {
                    currentModel = mdl
                    if firstModel.isEmpty { firstModel = mdl }
                }
                cwd = cwd ?? (payload["cwd"] as? String)

            case "event_msg":
                let pt = payload["type"] as? String
                if pt == "user_message" {
                    if title == nil, let msg = payload["message"] as? String {
                        let t = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                        // 跳过环境注入块：`<environment_context>`（`<` 开头）与 IDE 扩展的 `# Context from my IDE setup:…`
                        if !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("# Context from") {
                            title = String(t.prefix(60))
                        }
                    }
                } else if pt == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let usage = info["total_token_usage"] as? [String: Any],
                          let tsStr = obj["timestamp"] as? String,
                          let ts = ISODateParser.parse(tsStr) {
                    // 与 CodexProvider.parseRawEvents 同一解析（含 total_tokens 回退、last 可缺）
                    let last = (info["last_token_usage"] as? [String: Any]).map(CodexProvider.usageVector)
                    events.append(Ev(ts: ts, total: CodexProvider.usageVector(usage), last: last, model: currentModel))
                    lastTs = max(lastTs, ts)
                }

            default:
                break
            }
        }

        guard !events.isEmpty else { return nil }
        let meta = Meta(ownId: ownId, forkedFromId: forkedFrom, isSubagent: isSub,
                        title: title, cwd: cwd, firstModel: firstModel, lastActivity: lastTs)
        return FileParse(events: events, meta: meta)
    }
}
