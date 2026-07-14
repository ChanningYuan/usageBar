import Foundation
import usageBarCore

/// WorkBuddy 明细扫描器（v0.3.22 新增）。
///
/// 数据源 `~/.workbuddy/projects/<工程>/<sessionId>.jsonl`，token 在 `providerData.rawUsage`
/// （OpenAI 命名 + 扩展）。**口径与 `WorkBuddyProvider.parseFile` 逐字对齐**，否则明细之和对不上主行：
///
/// - `total = prompt_tokens + completion_tokens` —— **prompt 已含缓存**（子集内含，同 Codex/QoderIde）
/// - 命中读取的权威字段是 **`prompt_cache_hit_tokens`**
///   （⚠️ 勿用顶层 `cached_tokens`（=0 是坑）、勿用 `cache_read_input_tokens`（该 provider 恒 0））
/// - → 净输入 = `prompt − 命中读`，缓存读 = 命中读，输出 = `completion`，思考 = `completion_thinking_tokens`（⊂ 输出）
/// - **没有「缓存写」这一列** → 指标区只有 3 块（净输入 / 输出⊃思考 / 缓存读）
///
/// ## 金额走「信用点」，不查价目表
/// `rawUsage.credit` 是 WorkBuddy 自带的**内部积分**（本机实测 `6.78` / 47,499 token）。
/// 之所以不查价目表：它的模型名是 `auto`（厂商打码），而远程价目表里恰好有个毫不相干的
/// `llmgateway/auto`（单价全 0）会被误命中 → 静默显示 $0（这个 bug 已在 `UnifiedPricing.hasNoPricing` 修）。
/// 既然真模型名拿不到、等效美元算不出来，就直接用数据自带的 credit。
///
/// ⚠️ **credit 是整条消息的一个标量，拆不到「净输入/输出/缓存」四列**（等效美元能拆是因为每列有单价）
/// → 指标区四格的金额位显示 `—`；只有 Hero 总额 / 按模型 / 按会话能显示 Credits。
///
/// 将来若支持 BYOK（自带 key）：那时真实模型名是本地已知的（用户自己填 provider/model/url）
/// → 该行自动升级到「等效美元」档。档位按**行**判定，不写死在 provider 上（见 `CostUnit`）。
public actor WorkBuddyDetailScanner {
    public static let shared = WorkBuddyDetailScanner()
    public init() {}

    struct Row {
        let date: String
        let sessionId: String
        let model: String
        let tokens: TokenBreakdown
        let credit: Double
        let time: Date
    }

    /// sessionId → 会话标题的三档来源（优先级从高到低）
    struct SessionMeta {
        var aiTitle: String?        // WorkBuddy 自己写的 `type=="ai-title"` 行（和 Claude Code 同款）
        var firstUserText: String?  // 首条真实用户输入
        var cwd: String?            // 兜底：工作目录名
    }

    struct FileParse {
        let rows: [Row]
        let metas: [String: SessionMeta]
    }

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let parse: FileParse
    }

    private var cache: [String: CacheEntry] = [:]

    private var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/projects")
    }

    public func detail(window: TimeWindow, weekStartMonday: Bool = true,
                       now: Date = Date()) async -> ProviderDetail {
        var rows: [Row] = []
        var metas: [String: SessionMeta] = [:]

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return .empty(providerId: "workbuddy", windowId: window.id)
        }
        for url in JSONLReader.findFiles(under: projectsDir, where: { $0.pathExtension == "jsonl" }) {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }
            let fp: FileParse
            if let c = cache[path], c.mtime == meta.mtime, c.size == meta.size {
                fp = c.parse
            } else {
                fp = Self.parse(url: url)
                cache[path] = CacheEntry(mtime: meta.mtime, size: meta.size, parse: fp)
            }
            rows.append(contentsOf: fp.rows)
            for (sid, m) in fp.metas {
                var cur = metas[sid] ?? SessionMeta()
                cur.aiTitle = m.aiTitle ?? cur.aiTitle
                cur.firstUserText = cur.firstUserText ?? m.firstUserText
                cur.cwd = cur.cwd ?? m.cwd
                metas[sid] = cur
            }
        }

        return Self.compose(rows: rows, metas: metas, window: window,
                            weekStartMonday: weekStartMonday, now: now)
    }

    /// 纯聚合（静态、无 IO，单测直接打）
    static func compose(rows: [Row], metas: [String: SessionMeta], window: TimeWindow,
                        weekStartMonday: Bool, now: Date) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        var total = TokenBreakdown()
        var totalCredit = 0.0
        var byModel: [String: (tb: TokenBreakdown, credit: Double)] = [:]
        var bySession: [String: (tb: TokenBreakdown, credit: Double, last: Date)] = [:]

        for r in rows where inWindow(r.date) {
            total.add(r.tokens)
            totalCredit += r.credit

            var m = byModel[r.model] ?? (TokenBreakdown(), 0)
            m.tb.add(r.tokens); m.credit += r.credit
            byModel[r.model] = m

            var s = bySession[r.sessionId] ?? (TokenBreakdown(), 0, r.time)
            s.tb.add(r.tokens); s.credit += r.credit; s.last = max(s.last, r.time)
            bySession[r.sessionId] = s
        }

        // `cost` 字段在 `.credits` 档下装的是**积分**（不是美元）。展示层按 `spec.costUnit` 决定单位。
        let models = byModel.map { ModelDetailRecord(modelId: $0.key, tokens: $0.value.tb, cost: $0.value.credit) }
            .sorted { $0.tokens.total > $1.tokens.total }

        // 标题优先级：ai-title（WorkBuddy 自己生成的会话名）> 首条真实用户输入 > 工作目录名 > 兜底
        let sessions = bySession.map { sid, v -> SessionDetailRecord in
            let m = metas[sid]
            let title = m?.aiTitle
                ?? m?.firstUserText
                ?? m?.cwd.map { ($0 as NSString).lastPathComponent }
                ?? "(无标题会话)"
            return SessionDetailRecord(
                sessionId: sid, title: title, subtitle: String(sid.prefix(8)),
                lastActivity: v.last, tokens: v.tb, cost: v.credit)
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(providerId: "workbuddy", windowId: window.id,
                              tokens: total, cost: totalCredit,
                              models: models, sessions: sessions)
    }

    // MARK: - 单文件解析（窗口无关）

    static func parse(url: URL) -> FileParse {
        var rows: [Row] = []
        var metas: [String: SessionMeta] = [:]

        try? JSONLReader.forEachLine(at: url) { obj in
            let type = obj["type"] as? String
            let sid = (obj["sessionId"] as? String) ?? ""
            guard !sid.isEmpty else { return }

            // ── 会话标题：WorkBuddy 自己写的 `ai-title` 行（和 Claude Code 同款，v0.3.23 才接上）
            if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty {
                var m = metas[sid] ?? SessionMeta()
                m.aiTitle = String(t.prefix(80))   // 取最后一条（后写覆盖前写）
                metas[sid] = m
                return
            }

            guard type == "message" else { return }
            let role = obj["role"] as? String

            // ── 首条真实用户输入（兜底标题）
            // ⚠️ `content` 是**块数组** `[{type:"text", text:"..."}]`，不是字符串。
            //    首块常是 `<system-reminder>` 之类的系统注入 → 必须跳过，否则标题是一坨垃圾。
            if role == "user", metas[sid]?.firstUserText == nil,
               let text = Self.plainUserText(obj["content"]) {
                var m = metas[sid] ?? SessionMeta()
                m.firstUserText = text
                m.cwd = m.cwd ?? (obj["cwd"] as? String)
                metas[sid] = m
            }

            guard role == "assistant",
                  let pd = obj["providerData"] as? [String: Any],
                  let usage = pd["rawUsage"] as? [String: Any],
                  let ts = parseEpochMillis(obj["timestamp"]) else { return }

            let prompt = (usage["prompt_tokens"] as? Int) ?? 0
            let completion = (usage["completion_tokens"] as? Int) ?? 0
            if prompt + completion == 0 { return }

            // 与主行同源：命中读只认 prompt_cache_hit_tokens；prompt 已含它 → 净输入要减掉
            let cachedHit = min((usage["prompt_cache_hit_tokens"] as? Int) ?? 0, prompt)
            let thinking = (usage["completion_thinking_tokens"] as? Int) ?? 0

            let tb = TokenBreakdown(
                input: prompt - cachedHit,
                output: completion,
                cacheCreate5m: 0, cacheCreate1h: 0,   // WorkBuddy 无「缓存写」列
                cacheRead: cachedHit,
                reasoning: min(thinking, completion))  // 思考 ⊂ 输出

            let credit = (usage["credit"] as? Double)
                ?? Double((usage["credit"] as? Int) ?? 0)

            let model = (pd["model"] as? String) ?? ""
            var m = metas[sid] ?? SessionMeta()
            m.cwd = m.cwd ?? (obj["cwd"] as? String)
            metas[sid] = m

            rows.append(Row(date: DailyAggregator.dateString(for: ts), sessionId: sid,
                            model: model.isEmpty ? "(未知)" : model,
                            tokens: tb, credit: credit, time: ts))
        }
        return FileParse(rows: rows, metas: metas)
    }

    /// 从 `content` 提取可读首句。`content` 是块数组 `[{type:"text", text:"..."}]`。
    /// 跳过 `<system-reminder>` / `<command-...>` 这类尖括号包裹的系统注入块 —— 它们不是用户说的话。
    static func plainUserText(_ content: Any?) -> String? {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("<") { return nil }
            return String(t.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        }
        if let s = content as? String { return clean(s) }
        if let arr = content as? [[String: Any]] {
            for part in arr where (part["type"] as? String) == "text" {
                if let s = part["text"] as? String, let c = clean(s) { return c }
            }
        }
        return nil
    }

    /// epoch 毫秒（Int / Double / NSNumber）→ Date。与 `WorkBuddyProvider` 同一套。
    static func parseEpochMillis(_ value: Any?) -> Date? {
        let ms: Double
        if let i = value as? Int { ms = Double(i) }
        else if let d = value as? Double { ms = d }
        else if let n = value as? NSNumber { ms = n.doubleValue }
        else { return nil }
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }
}
