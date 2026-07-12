import Foundation
import usageBarCore

/// Codex 详情懒加载扫描器（drill-in 展开分会话 / 分模型时才跑，独立于主刷新快路径）。
///
/// 数据源 `~/.codex/sessions/**/rollout-*.jsonl`。与主行 `CodexProvider` 同源、同 fork 去重口径
/// （baseline + 峰值跟踪），但按 (model, session, date) 聚出四维 token（净输入 / 缓存命中 / 输出 / 思考）。
///
/// ── 与 Claude 扫描器的关键差异 ──
///  1. Codex 的 `token_count` 事件给的是**会话累计**（`total_token_usage`），需相邻事件差分求增量。
///  2. model 不在 token_count 里、而在 `turn_context.payload.model`；按出现顺序跟踪「当前模型」再归账。
///  3. 无 ai-title：标题取首条 `event_msg/user_message`（跳过 `<...>` 环境注入块），兜底 cwd 目录名。
///  4. fork：`session_meta.forked_from_id` 存在时用父会话 final 作差分基线（同 `CodexProvider` 信号1）。
///
/// 带按文件 mtime 的内存缓存（缓存的是「原始事件 + meta」，窗口无关）；差分 / 归窗在 `detail()` 里做，
/// 因为 fork 基线依赖跨文件的处理顺序。
public actor CodexDetailScanner {
    public static let shared = CodexDetailScanner()
    public init() {}

    /// token_count.total_token_usage 的累计快照（四维）。
    private struct Cumul {
        var input = 0        // input_tokens（含 cached）
        var cached = 0       // cached_input_tokens（input 子集）
        var output = 0       // output_tokens（含 reasoning）
        var reasoning = 0    // reasoning_output_tokens（output 子集）
    }

    private struct Ev {
        let ts: Date
        let model: String
        let c: Cumul
    }

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

    /// 扫描并聚合 Codex 在某窗口的明细（分模型 + 分会话 + 四维 Hero）。
    public func detail(providerId: String, window: TimeWindow,
                       weekStartMonday: Bool = true, now: Date = Date()) async -> ProviderDetail {
        // 文件名 `rollout-{ISO时间}-{uuid}` 字典序 == 时间序 → 父会话一定排在它的 fork 之前。
        let files = allFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)
        let threadNames = loadThreadNames()   // sessionId → Codex 侧栏标题

        var sessionFinal: [String: Cumul] = [:]   // ownId → 峰值累计（fork baseline 用）
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

            // baseline 决策（同 CodexProvider）：subagent 短路 > fork 信号1 > 默认 0。
            var prev = Cumul()
            if !meta.isSubagent, let parent = meta.forkedFromId, let pf = sessionFinal[parent] {
                prev = pf
            }
            var fileFinal = prev

            for ev in fp.events {
                let dIn = max(0, ev.c.input - prev.input)
                let dCa = max(0, ev.c.cached - prev.cached)
                let dOut = max(0, ev.c.output - prev.output)
                let dRe = max(0, ev.c.reasoning - prev.reasoning)
                prev.input = max(prev.input, ev.c.input)
                prev.cached = max(prev.cached, ev.c.cached)
                prev.output = max(prev.output, ev.c.output)
                prev.reasoning = max(prev.reasoning, ev.c.reasoning)
                fileFinal = prev

                let net = max(0, dIn - dCa)              // 净输入 = 增量输入 − 增量缓存命中
                if net == 0 && dCa == 0 && dOut == 0 { continue }
                let date = DailyAggregator.dateString(for: ev.ts)
                guard inWindow(date) else { continue }

                let tb = TokenBreakdown(input: net, output: dOut, cacheRead: dCa, reasoning: min(dRe, dOut))
                let model = ev.model.isEmpty ? meta.firstModel : ev.model
                let c = UnifiedPricing.cost(tb, modelId: model)
                hero.add(tb); heroCost += c
                byModel[model, default: TokenBreakdown()].add(tb); modelCost[model, default: 0] += c
                bySession[sid, default: TokenBreakdown()].add(tb); sessionCost[sid, default: 0] += c
            }

            if !meta.ownId.isEmpty {
                var f = sessionFinal[meta.ownId] ?? Cumul()
                f.input = max(f.input, fileFinal.input)
                f.cached = max(f.cached, fileFinal.cached)
                f.output = max(f.output, fileFinal.output)
                f.reasoning = max(f.reasoning, fileFinal.reasoning)
                sessionFinal[meta.ownId] = f
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
            ModelDetailRecord(modelId: mid, displayName: CodexPricing.displayName(for: mid),
                              tokens: tb, cost: modelCost[mid] ?? 0)
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

    // MARK: - 文件枚举（与 CodexProvider 同源）

    private func allFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return JSONLReader.findFiles(under: dir) { url in
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        }
    }

    /// Codex 会话正经标题源：`~/.codex/session_index.jsonl`（每行 `{id, thread_name, updated_at}`，
    /// 与 Codex Desktop 侧栏同一份）。返回 sessionId → thread_name。每次 `detail()` 现读、始终最新。
    private func loadThreadNames() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".codex/session_index.jsonl")
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
                    var c = Cumul()
                    c.input = (usage["input_tokens"] as? Int) ?? 0
                    c.cached = (usage["cached_input_tokens"] as? Int) ?? 0
                    c.output = (usage["output_tokens"] as? Int) ?? 0
                    c.reasoning = (usage["reasoning_output_tokens"] as? Int) ?? 0
                    events.append(Ev(ts: ts, model: currentModel, c: c))
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
