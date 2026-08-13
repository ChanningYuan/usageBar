import Foundation
import usageBarCore

/// Claude 详情懒加载扫描器（drill-in 展开分会话 / 分模型时才跑，独立于主刷新快路径）。
///
/// 复用 `~/.claude/projects/*/*.jsonl`（含 subagents/），按 (source, sessionId, model, date)
/// 聚合 5 列 token，并解析 ai-title / 首条用户输入 / cwd 作为会话标题。
///
/// 带独立的「按文件 mtime 内存缓存」：窗口切换只做便宜的重聚合、不重解析；数据变了调 `invalidate()`。
/// 与主行完全同源、同去重口径（message.id 文件内去重）；主行统一归 `claude-code`，
/// 详情再按官方直连 / 中转代理两类来源解释构成。
public actor ClaudeDetailScanner {
    public static let shared = ClaudeDetailScanner()
    public init() {}

    // MARK: - 缓存单元（窗口无关，按文件缓存）

    fileprivate struct Unit {
        let source: ClaudeSource
        let sessionId: String
        let model: String
        let date: String
        var tokens: TokenBreakdown
    }

    fileprivate struct SessionMeta {
        var customTitle: String? = nil
        var aiTitle: String?
        var firstUserText: String?
        var cwd: String?
        var lastActivity: Date
    }

    fileprivate struct FileParse {
        let units: [Unit]
        let metas: [String: SessionMeta]
    }

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let parse: FileParse
    }

    private var cache: [String: CacheEntry] = [:]

    // MARK: - 对外入口

    /// 扫描并聚合某个 Claude 同构 transcript 源在某窗口的明细。
    ///
    /// ⚠️ 文件源必须由调用方传入（v0.3.22 起）。此前这里的路径是**写死**的 `~/.claude/projects`、
    /// 完全无视传进来的 `providerId` —— Cowork 等同构 provider 一旦放开 drill-in，就会把
    /// **Claude Code 的数据当成自己的显示**。当时只是被 `UsageView` 的手写白名单恰好挡住，bug 未暴露。
    /// 现在文件源随 provider 声明表（`ProviderDetailSpec.scanner`）下发，同源不同根，互不串。
    ///
    /// `includeHidden` / `requirePath` / `excludePath` 必须与对应 provider 的**主行扫描口径逐字一致**，
    /// 否则详情页的分项之和会对不上列表主行。
    public func detail(providerId: String, root: URL,
                       includeHidden: Bool = false,
                       requirePath: String? = nil,
                       excludePath: String? = nil,
                       window: TimeWindow,
                       weekStartMonday: Bool = true, now: Date = Date()) async -> ProviderDetail {
        var units: [Unit] = []
        var metas: [String: SessionMeta] = [:]

        for url in allFiles(root: root, includeHidden: includeHidden,
                            requirePath: requirePath, excludePath: excludePath) {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }

            let fp: FileParse
            if let c = cache[path], c.mtime == meta.mtime, c.size == meta.size {
                fp = c.parse
            } else {
                fp = parse(url: url)
                cache[path] = CacheEntry(mtime: meta.mtime, size: meta.size, parse: fp)
            }

            units.append(contentsOf: fp.units)
            for (sid, m) in fp.metas {
                if var existing = metas[sid] {
                    existing.customTitle = m.customTitle ?? existing.customTitle
                    existing.aiTitle = m.aiTitle ?? existing.aiTitle
                    existing.firstUserText = existing.firstUserText ?? m.firstUserText
                    existing.cwd = existing.cwd ?? m.cwd
                    existing.lastActivity = max(existing.lastActivity, m.lastActivity)
                    metas[sid] = existing
                } else {
                    metas[sid] = m
                }
            }
        }

        return aggregate(providerId: providerId, window: window,
                         weekStartMonday: weekStartMonday, now: now,
                         units: units, metas: metas)
    }

    /// 数据可能已变（主刷新后）→ 清缓存，下次重扫。
    public func invalidate() { cache.removeAll() }

    /// 解析单个 transcript，产出**写进持久账本的明细条目**（v0.3.33 起）。
    ///
    /// 由各 provider 在**主扫盘**时调用：同一次文件解析既算主行总量、又落明细，
    /// 详情页此后从账本读，不再重扫源文件（根治 issue #8 的列表/详情分叉）。
    ///
    /// `attachSource`：Claude Code 才需要区分官方直连 / 中转代理（详情页「按来源」区）。
    /// 其余复用本解析器的 provider（Cowork / Qoder CLI）传 false，`source` 存 nil。
    nonisolated public static func detailRecords(url: URL, providerId: String,
                                                 attachSource: Bool) -> [FileDetailRecord] {
        let fp = parseTranscript(url: url)
        return fp.units.map { u in
            let m = fp.metas[u.sessionId]
            let title = m?.customTitle
                ?? m?.aiTitle
                ?? m?.firstUserText
                ?? m?.cwd.map { ($0 as NSString).lastPathComponent }
                ?? ""
            return FileDetailRecord(
                provider: providerId, date: u.date, sessionId: u.sessionId,
                title: title, model: u.model,
                lastActivity: m?.lastActivity ?? .distantPast,
                tokens: u.tokens,
                source: attachSource ? u.source.rawValue : nil)
        }
    }

    // MARK: - 文件枚举（与 ClaudeJsonlScanner 同源）

    /// 列出该源下的所有 transcript。源由调用方给（见 `detail(providerId:root:...)` 的说明）。
    private func allFiles(root: URL, includeHidden: Bool,
                          requirePath: String?, excludePath: String?) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return JSONLReader.findFiles(under: root, includeHidden: includeHidden) { url in
            guard url.pathExtension == "jsonl" else { return false }
            if let req = requirePath, !url.path.contains(req) { return false }
            if let exc = excludePath, url.path.contains(exc) { return false }
            return true
        }
    }

    // MARK: - 单文件解析（窗口无关）

    private func parse(url: URL) -> FileParse { Self.parseTranscript(url: url) }

    /// 纯解析（无状态，可从 actor 外调用）。实例方法 `parse` 与账本入口 `detailRecords` 共用它，
    /// 保证「主扫盘写账本」和「详情页兜底重扫」两条路径逐字同口径。
    nonisolated fileprivate static func parseTranscript(url: URL) -> FileParse {
        var acc: [String: Unit] = [:]          // key = source|session|model|date
        var metas: [String: SessionMeta] = [:]
        var seenIds = Set<String>()

        try? JSONLReader.forEachLine(at: url) { obj in
            let type = obj["type"] as? String
            let sid = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String) ?? ""
            guard !sid.isEmpty else { return }

            switch type {
            case "assistant":
                guard let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = ISODateParser.parse(tsStr) else { return }

                let messageId = (message["id"] as? String) ?? ""
                if !messageId.isEmpty {
                    if seenIds.contains(messageId) { return }
                    seenIds.insert(messageId)
                }

                let model = (message["model"] as? String) ?? ""
                if model.isEmpty || model == "<synthetic>" { return }

                let source = ClaudeSource.classify(messageId: messageId, modelId: model)

                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                var c5 = 0, c1 = 0
                if let cc = usage["cache_creation"] as? [String: Any] {
                    c5 = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
                    c1 = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
                }
                if c5 == 0 && c1 == 0 {   // 旧 transcript 无拆分对象 → 整块归 5m
                    c5 = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                }

                let tb = TokenBreakdown(input: input, output: output,
                                        cacheCreate5m: c5, cacheCreate1h: c1, cacheRead: cacheRead)
                if tb.total == 0 { return }

                let date = DailyAggregator.dateString(for: ts)
                let key = "\(source.rawValue)|\(sid)|\(model)|\(date)"
                if var u = acc[key] {
                    u.tokens.add(tb); acc[key] = u
                } else {
                    acc[key] = Unit(source: source, sessionId: sid, model: model, date: date, tokens: tb)
                }

                var m = metas[sid] ?? SessionMeta(aiTitle: nil, firstUserText: nil, cwd: nil, lastActivity: ts)
                m.cwd = m.cwd ?? (obj["cwd"] as? String)
                m.lastActivity = max(m.lastActivity, ts)
                metas[sid] = m

            case "ai-title":
                if let t = (obj["aiTitle"] as? String), !t.isEmpty {
                    let ts = (obj["timestamp"] as? String).flatMap(ISODateParser.parse)
                        ?? metas[sid]?.lastActivity ?? .distantPast
                    var m = metas[sid] ?? SessionMeta(aiTitle: nil, firstUserText: nil, cwd: nil, lastActivity: ts)
                    m.aiTitle = t          // 取最后一条（后写覆盖前写）
                    metas[sid] = m
                }

            case "custom-title":
                // 用户 /rename 手动改名（`{"type":"custom-title","customTitle":"...","sessionId":"..."}`，
                // 无 timestamp）。优先级最高——手动命名是用户明确意图，压过 ai-title 自动标题。
                // 同版 rename 还会写一条 `agent-name`，此处不解析它：subagent 场景也用该类型，会误伤。
                if let t = (obj["customTitle"] as? String), !t.isEmpty {
                    let ts = metas[sid]?.lastActivity ?? .distantPast
                    var m = metas[sid] ?? SessionMeta(aiTitle: nil, firstUserText: nil, cwd: nil, lastActivity: ts)
                    m.customTitle = t      // 取最后一条（多次 rename 后写覆盖前写）
                    metas[sid] = m
                }

            case "user":
                if metas[sid]?.firstUserText == nil,
                   (obj["isMeta"] as? Bool) != true,
                   (obj["isSidechain"] as? Bool) != true,
                   let message = obj["message"] as? [String: Any],
                   let text = Self.plainUserText(message["content"]) {
                    let ts = (obj["timestamp"] as? String).flatMap(ISODateParser.parse) ?? .distantPast
                    var m = metas[sid] ?? SessionMeta(aiTitle: nil, firstUserText: nil, cwd: nil, lastActivity: ts)
                    m.firstUserText = text
                    m.cwd = m.cwd ?? (obj["cwd"] as? String)
                    metas[sid] = m
                }

            default:
                break
            }
        }

        return FileParse(units: Array(acc.values), metas: metas)
    }

    /// 从 user `message.content` 提取可读首句（跳过命令 / caveat / 工具结果块）。
    private static func plainUserText(_ content: Any?) -> String? {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if t.hasPrefix("<") { return nil }   // <command-...> / <local-command...> / caveat 包裹
            return String(t.prefix(80))
        }
        if let s = content as? String { return clean(s) }
        if let arr = content as? [[String: Any]] {
            for part in arr where (part["type"] as? String) == "text" {
                if let s = part["text"] as? String, let c = clean(s) { return c }
            }
        }
        return nil
    }

    // MARK: - 聚合（窗口相关）

    private func aggregate(providerId: String, window: TimeWindow,
                           weekStartMonday: Bool, now: Date,
                           units: [Unit], metas: [String: SessionMeta]) -> ProviderDetail {
        // ⚠️ v0.3.22 修复：这里原先有一道 `guard providerId == "claude-code" else { return .empty(...) }`。
        // 文件源虽然参数化了，但**聚合函数还硬判 providerId** → Cowork / Qoder CLI / Qoder Work
        // 三个复用本扫描器的 provider，详情页点进去**全是空的**（"该周期这个来源没有用量"）。
        // 本扫描器现在是「Claude 同构 transcript」的通用扫描器，不再是 claude-code 专属。
        //
        // `sources`（官方直连 / 中转代理）照常算——展示层由 `spec.hasSources` 决定要不要渲染，
        // 只有 Claude Code 声明了它；其余 provider 算了也不显示，无副作用。
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        var hero = TokenBreakdown()
        var heroCost = 0.0
        var bySource: [ClaudeSource: TokenBreakdown] = [:]
        var sourceCost: [ClaudeSource: Double] = [:]
        var byModel: [String: TokenBreakdown] = [:]
        var modelCost: [String: Double] = [:]
        var bySession: [String: TokenBreakdown] = [:]
        var sessionCost: [String: Double] = [:]

        for u in units where inWindow(u.date) {
            let c = UnifiedPricing.cost(u.tokens, modelId: u.model)
            hero.add(u.tokens); heroCost += c
            bySource[u.source, default: TokenBreakdown()].add(u.tokens)
            sourceCost[u.source, default: 0] += c
            byModel[u.model, default: TokenBreakdown()].add(u.tokens)
            modelCost[u.model, default: 0] += c
            bySession[u.sessionId, default: TokenBreakdown()].add(u.tokens)
            sessionCost[u.sessionId, default: 0] += c
        }

        let sources = ClaudeSource.allCases.compactMap { source -> SourceDetailRecord? in
            guard let tb = bySource[source], tb.total > 0 else { return nil }
            return SourceDetailRecord(source: source, tokens: tb, cost: sourceCost[source] ?? 0)
        }

        let models = byModel.map { (mid, tb) in
            ModelDetailRecord(modelId: mid, tokens: tb, cost: modelCost[mid] ?? 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        let sessions = bySession.map { (sid, tb) -> SessionDetailRecord in
            let m = metas[sid]
            let title = m?.customTitle
                ?? m?.aiTitle
                ?? m?.firstUserText
                ?? m?.cwd.map { ($0 as NSString).lastPathComponent }
                ?? "(无标题会话)"
            return SessionDetailRecord(sessionId: sid, title: title,
                                       subtitle: String(sid.prefix(8)),
                                       lastActivity: m?.lastActivity ?? .distantPast,
                                       tokens: tb, cost: sessionCost[sid] ?? 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(providerId: providerId, windowId: window.id,
                              tokens: hero, cost: heroCost, sources: sources,
                              models: models, sessions: sessions)
    }
}
