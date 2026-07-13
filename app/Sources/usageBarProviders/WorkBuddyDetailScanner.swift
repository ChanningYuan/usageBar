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

    struct FileParse {
        let rows: [Row]
        let titles: [String: String]   // sessionId → 首条用户输入
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
        var titles: [String: String] = [:]

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
            for (k, v) in fp.titles where titles[k] == nil { titles[k] = v }
        }

        return Self.compose(rows: rows, titles: titles, window: window,
                            weekStartMonday: weekStartMonday, now: now)
    }

    /// 纯聚合（静态、无 IO，单测直接打）
    static func compose(rows: [Row], titles: [String: String], window: TimeWindow,
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

        let sessions = bySession.map { sid, v -> SessionDetailRecord in
            let t = titles[sid] ?? ""
            return SessionDetailRecord(
                sessionId: sid,
                title: t.isEmpty ? String(sid.prefix(12)) : t,
                subtitle: String(sid.prefix(8)),
                lastActivity: v.last, tokens: v.tb, cost: v.credit)
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(providerId: "workbuddy", windowId: window.id,
                              tokens: total, cost: totalCredit,
                              models: models, sessions: sessions)
    }

    // MARK: - 单文件解析（窗口无关）

    static func parse(url: URL) -> FileParse {
        var rows: [Row] = []
        var titles: [String: String] = [:]

        try? JSONLReader.forEachLine(at: url) { obj in
            guard (obj["type"] as? String) == "message" else { return }
            let sid = (obj["sessionId"] as? String) ?? ""
            guard !sid.isEmpty else { return }
            let role = obj["role"] as? String

            // 会话标题：首条用户输入
            if role == "user", titles[sid] == nil,
               let c = obj["content"] as? String, !c.isEmpty {
                titles[sid] = String(c.prefix(40)).replacingOccurrences(of: "\n", with: " ")
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
            rows.append(Row(date: DailyAggregator.dateString(for: ts), sessionId: sid,
                            model: model.isEmpty ? "(未知)" : model,
                            tokens: tb, credit: credit, time: ts))
        }
        return FileParse(rows: rows, titles: titles)
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
