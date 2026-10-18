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
        var modelTiming: [String: GenerationTiming] = [:]
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
            guard !fp.events.isEmpty else { continue }
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
                modelTiming[model, default: GenerationTiming()].add(output: d.delta.output, millis: d.genMillis)
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
            ModelDetailRecord(modelId: mid, tokens: tb, cost: modelCost[mid] ?? 0,
                              timing: modelTiming[mid].flatMap { $0.millis > 0 ? $0 : nil })
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

    // MARK: - 账本明细（v0.3.48：一个对话文件一条，主列表的数由这些行汇总）

    /// 单个 rollout 文件 → 账本明细行（会话 × 模型 × 日期）+ 历史最大累计（给后面的分叉对话当基线）。
    ///
    /// ⚠️ 0.3.47 及以前是 `allDetails`：全部文件的明细合成**一条**账本、每轮按现存文件整条覆盖——
    /// 文件被 Codex 压缩（10-16 起）或被手动删掉，明细就跟着没了，主列表却还在（本机 79 天对不上）。
    /// 现在与 Claude Code 同一做法：明细和主列表存进同一条按文件的账本，文件没了这一条照样留着。
    /// 差分与归账与 `detail()` 逐字一致（`CodexLineage`）；`baseline` 由调用方按分叉规则给。
    ///
    /// 返回 nil = 这次读不了（压缩文件坏了 / 还没写完），调用方应保留上次的数。
    /// `keepInMemory`：分叉对话每轮要按最新基线重算，解析结果留在内存里；普通对话算完就进账本，不占内存。
    func fileDetails(url: URL, sessionKey: String, baseline: CodexUsage, providerId: String,
                     threadNames: [String: String], keepInMemory: Bool)
        -> (details: [FileDetailRecord], maxTotal: CodexUsage)? {
        guard let fp = cachedParse(url: url, keep: keepInMemory) else { return nil }
        let meta = fp.meta
        let sid = meta.ownId.isEmpty ? sessionKey : meta.ownId
        let r = CodexLineage.deltas(events: fp.events, baseline: baseline)

        var acc: [String: TokenBreakdown] = [:]          // key = model|date
        var accTiming: [String: GenerationTiming] = [:]
        var lastAt = Date.distantPast
        for d in r.deltas where d.delta.total > 0 {
            let date = DailyAggregator.dateString(for: d.ts)
            let model = d.model.isEmpty ? meta.firstModel : d.model
            let key = "\(model)\u{0}\(date)"
            acc[key, default: TokenBreakdown()].add(Self.breakdown(d.delta))
            // 只给「真实计入」的增量计时（继承快照 / replay / 重复事件根本不产出增量），输出用计入的那个数
            accTiming[key, default: GenerationTiming()].add(output: d.delta.output, millis: d.genMillis)
            lastAt = max(lastAt, d.ts)
        }
        let title = threadNames[sid] ?? meta.title
            ?? meta.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        let details = acc.map { key, tb -> FileDetailRecord in
            let parts = key.components(separatedBy: "\u{0}")
            return FileDetailRecord(provider: providerId, date: parts[1], sessionId: sid,
                                    title: title, model: parts[0],
                                    lastActivity: lastAt == .distantPast ? meta.lastActivity : lastAt,
                                    tokens: tb, timing: accTiming[key] ?? GenerationTiming())
        }.sorted { ($0.date, $0.model) < ($1.date, $1.model) }
        return (details, r.maxTotal)
    }

    /// 侧栏标题（每轮现读，改名后下一轮就跟上）
    func threadNames(sessionsDir: URL) -> [String: String] {
        loadThreadNames(sessionsDir: sessionsDir)
    }

    /// 文件头的 session_meta（是不是分叉、原对话是谁），按修改时间 + 大小缓存在内存里。
    /// 压缩文件每次读都要解压开头一段，209 个文件每轮约 0.14 秒（v0.3.48 实测），文件没变就别再解。
    func sessionMeta(url: URL) -> CodexProvider.SessionMeta? {
        let path = url.path
        guard let m = FileMetadata.read(at: path) else { return nil }
        if let c = metaCache[path], c.mtime == m.mtime, c.size == m.size { return c.meta }
        let meta = CodexProvider.readFirstSessionMeta(url: url)
        metaCache[path] = (m.mtime, m.size, meta)
        return meta
    }

    private var metaCache: [String: (mtime: Date, size: Int, meta: CodexProvider.SessionMeta?)] = [:]

    private func cachedParse(url: URL, keep: Bool) -> FileParse? {
        let path = url.path
        guard let m = FileMetadata.read(at: path) else { return nil }
        if let c = cache[path], c.mtime == m.mtime, c.size == m.size { return c.parse }
        let parsed = parse(url: url)
        if keep, let parsed {
            cache[path] = CacheEntry(mtime: m.mtime, size: m.size, parse: parsed)
        } else {
            cache.removeValue(forKey: path)
        }
        return parsed
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

    /// 模型生成的内容（计入「回答完」时间）
    private static let generatedItemTypes: Set<String> = [
        "reasoning", "function_call", "custom_tool_call", "local_shell_call", "web_search_call", "tool_search_call",
    ]
    /// 送进模型的输入（计入「请求发出」时间）
    private static let inputItemTypes: Set<String> = [
        "function_call_output", "custom_tool_call_output", "local_shell_call_output", "tool_search_output",
    ]

    private func parse(url: URL) -> FileParse? {
        var events: [Ev] = []
        var ownId = ""; var forkedFrom: String? = nil; var isSub = false
        var title: String? = nil; var cwd: String? = nil
        var currentModel = ""; var firstModel = ""
        var lastTs = Date.distantPast
        // ── 输出速度（v0.3.47）。⚠️ 用量事件（token_count，新版还有 token_usage_record）**不能**当「回答完」：
        // 实测它常在工具执行完、工具结果写入之后才落盘，拿它当结束会把工具耗时算进去、或算出 1 毫秒。
        // 结束 = 本次请求最后一个生成内容（思考 / 回答 / 工具调用）写入的时间；
        // 开始 = 第一个生成内容之前最后一条输入（用户消息 / 工具结果 / 任务开始）的时间，没有就用上一次请求的结束。
        // 时间先存原串：Codex 一律写 `2026-10-13T06:02:21.649Z` 定长 UTC 串，字典序 == 时间序，
        // 只在每次请求结束时解析两个，省掉每行一次日期解析（Codex 日志动辄 GB 级）。
        var genTs: [String] = []
        var inputTs: [String] = []
        var prevEnd: String? = nil

        do { try JSONLReader.forEachLine(at: url) { obj in
            guard let type = obj["type"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { return }
            switch type {
            case "response_item":
                guard let ts = obj["timestamp"] as? String else { return }
                let pt = payload["type"] as? String ?? ""
                let role = payload["role"] as? String
                if Self.generatedItemTypes.contains(pt) || (pt == "message" && role == "assistant") {
                    genTs.append(ts)
                } else if Self.inputItemTypes.contains(pt)
                            || (pt == "message" && (role == "user" || role == "developer")) {
                    inputTs.append(ts)
                }

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
                if pt == "user_message" || pt == "task_started", let ts = obj["timestamp"] as? String {
                    inputTs.append(ts)
                }
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
                    var genMillis: Int? = nil
                    if let first = genTs.min(), let end = genTs.max() {
                        let start = inputTs.filter { $0 <= first }.max() ?? prevEnd
                        if let s = start.flatMap(ISODateParser.parse), let e = ISODateParser.parse(end) {
                            genMillis = GenerationTiming.millis(from: s, to: e)
                        }
                        inputTs.removeAll { $0 <= end }   // 晚于结束的输入（本次的工具结果）留给下一次请求
                        genTs.removeAll()
                        prevEnd = end
                    }   // 没有新生成内容 = 重复的用量事件，不计时，缓冲留着
                    events.append(Ev(ts: ts, total: CodexProvider.usageVector(usage), last: last,
                                     model: currentModel, genMillis: genMillis))
                    lastTs = max(lastTs, ts)
                }

            default:
                break
            }
        } } catch {
            return nil   // 压缩文件坏了 / 还没写完：这次读不了，别拿读了一半的数入账
        }

        // 没有用量事件（刚建的对话等）照样返回：调用方据此写一条空账本，下轮文件不变就不用重读
        let meta = Meta(ownId: ownId, forkedFromId: forkedFrom, isSubagent: isSub,
                        title: title, cwd: cwd, firstModel: firstModel, lastActivity: lastTs)
        return FileParse(events: events, meta: meta)
    }
}
