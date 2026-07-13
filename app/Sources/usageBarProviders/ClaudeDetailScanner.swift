import Foundation
import usageBarCore

/// Claude 详情懒加载扫描器（drill-in 展开分会话 / 分模型时才跑，独立于主刷新快路径）。
///
/// 复用 `~/.claude/projects/*/*.jsonl`（含 subagents/），但按 (provider, sessionId, model, date)
/// 聚合 5 列 token，并解析 ai-title / 首条用户输入 / cwd 作为会话标题。
///
/// 带独立的「按文件 mtime 内存缓存」：窗口切换只做便宜的重聚合、不重解析；数据变了调 `invalidate()`。
/// 与主行完全同源、同去重口径（message.id 文件内去重、msg_vrtx_/msg_bdrk_ 前缀分 sub/api），
/// 因此详情合计能跟菜单栏主行对得上。
public actor ClaudeDetailScanner {
    public static let shared = ClaudeDetailScanner()
    public init() {}

    // MARK: - 缓存单元（窗口无关，按文件缓存）

    private struct Unit {
        let provider: String
        let sessionId: String
        let model: String
        let date: String
        var tokens: TokenBreakdown
    }

    private struct SessionMeta {
        var aiTitle: String?
        var firstUserText: String?
        var cwd: String?
        var lastActivity: Date
    }

    private struct FileParse {
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

    /// 扫描并聚合某 provider（claude-sub / claude-api）在某窗口的明细。
    public func detail(providerId: String, window: TimeWindow,
                       weekStartMonday: Bool = true, now: Date = Date()) async -> ProviderDetail {
        var units: [Unit] = []
        var metas: [String: SessionMeta] = [:]

        for url in allFiles() {
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

    // MARK: - 文件枚举（与 ClaudeJsonlScanner 同源）

    private func allFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return JSONLReader.findFiles(under: dir) { $0.pathExtension == "jsonl" }
    }

    // MARK: - 单文件解析（窗口无关）

    private func parse(url: URL) -> FileParse {
        var acc: [String: Unit] = [:]          // key = provider|session|model|date
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

                let provider = (messageId.hasPrefix("msg_vrtx_") || messageId.hasPrefix("msg_bdrk_"))
                    ? "claude-api" : "claude-sub"

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
                let key = "\(provider)|\(sid)|\(model)|\(date)"
                if var u = acc[key] {
                    u.tokens.add(tb); acc[key] = u
                } else {
                    acc[key] = Unit(provider: provider, sessionId: sid, model: model, date: date, tokens: tb)
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
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        var hero = TokenBreakdown()
        var heroCost = 0.0
        var byModel: [String: TokenBreakdown] = [:]
        var modelCost: [String: Double] = [:]
        var bySession: [String: TokenBreakdown] = [:]
        var sessionCost: [String: Double] = [:]

        for u in units where u.provider == providerId && inWindow(u.date) {
            let c = UnifiedPricing.cost(u.tokens, modelId: u.model)
            hero.add(u.tokens); heroCost += c
            byModel[u.model, default: TokenBreakdown()].add(u.tokens)
            modelCost[u.model, default: 0] += c
            bySession[u.sessionId, default: TokenBreakdown()].add(u.tokens)
            sessionCost[u.sessionId, default: 0] += c
        }

        let models = byModel.map { (mid, tb) in
            ModelDetailRecord(modelId: mid, tokens: tb, cost: modelCost[mid] ?? 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        let sessions = bySession.map { (sid, tb) -> SessionDetailRecord in
            let m = metas[sid]
            let title = m?.aiTitle
                ?? m?.firstUserText
                ?? m?.cwd.map { ($0 as NSString).lastPathComponent }
                ?? "(无标题会话)"
            return SessionDetailRecord(sessionId: sid, title: title,
                                       subtitle: String(sid.prefix(8)),
                                       lastActivity: m?.lastActivity ?? .distantPast,
                                       tokens: tb, cost: sessionCost[sid] ?? 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(providerId: providerId, windowId: window.id,
                              tokens: hero, cost: heroCost, models: models, sessions: sessions)
    }
}
