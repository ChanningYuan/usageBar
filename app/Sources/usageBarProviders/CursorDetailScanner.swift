import Foundation
import usageBarCore

/// Cursor 明细扫描器（v0.3.22 新增）。
///
/// 数据源 = 本地 mirror `~/Library/Application Support/usageBar/cursor-usage-capture.jsonl`，
/// 与主行 `CursorProvider.aggregate` **同一套「同 (时间戳,模型) 取终值」口径**，保证明细合计对得上主行。
///
/// ## ⚠️ 没有「按会话」
/// mirror 里**根本没有 conversationId 字段**（实测字段只有 `cache_creation_input_tokens` /
/// `cache_read_input_tokens` / `completion_tokens` / `cost` / `model` / `prompt_tokens` /
/// `source` / `timestamp` / `total_tokens`）。服务端的 `get-filtered-usage-events` 接口有
/// `conversationId`，但换数据源是另一条独立的工程风险（POST + Origin 头），且**只对换完之后新抓的数据有效**
/// —— 07-07 之前的历史（旧月抛号）永远补不回会话 id。故本版 `hasSessions: false`，详情页整块缺席。
///
/// ## ⚠️ 金额走价目表，不用 mirror 里的 cost
/// mirror 的 `cost` 字段记的**不是总花费，而是超出套餐的额外扣费**：实测累计 56,835,066 token 的
/// `cost` 合计仅 **$2.38**，占大头的 `claude-fable-5-thinking-high`（49,677,719 token）是 **$0.00**
/// （套餐内），不少行的值还是字符串 `"-"`。照它显示会得到「4970 万 token，花费 $0」的荒谬结果。
/// 而 Cursor 的**模型名是真的**（`claude-fable-5-thinking-high` 剥掉 `high`/`thinking` 两个尾段即命中
/// 价目表的 `claude-fable-5`），等效美元完全算得出来 → 走 `UnifiedPricing`，与其余 provider 同口径。
public actor CursorDetailScanner {
    public static let shared = CursorDetailScanner()
    public init() {}

    /// mirror 的一条快照（已按 key 收敛为终值）
    struct Snapshot {
        let date: String          // 日界串，窗口过滤用
        let model: String
        let tokens: TokenBreakdown
    }

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let snapshots: [Snapshot]
    }

    private var cache: CacheEntry?

    public func detail(window: TimeWindow, weekStartMonday: Bool = true,
                       now: Date = Date()) async -> ProviderDetail {
        Self.compose(snapshots: load(), window: window,
                     weekStartMonday: weekStartMonday, now: now)
    }

    /// 纯聚合（静态、无 IO，单测直接打）
    static func compose(snapshots: [Snapshot], window: TimeWindow,
                        weekStartMonday: Bool, now: Date) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        var total = TokenBreakdown()
        var totalCost = 0.0
        var byModel: [String: TokenBreakdown] = [:]

        for s in snapshots where inWindow(s.date) {
            total.add(s.tokens)
            byModel[s.model, default: TokenBreakdown()].add(s.tokens)
        }

        let models = byModel.map { mid, tb -> ModelDetailRecord in
            let c = UnifiedPricing.cost(tb, modelId: mid)
            totalCost += c
            return ModelDetailRecord(modelId: mid, tokens: tb, cost: c)
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(
            providerId: "cursor",
            windowId: window.id,
            tokens: total,
            cost: totalCost,
            models: models,
            sessions: []          // Cursor 无会话维度（见类型说明）
        )
    }

    // MARK: - 读 mirror（按 mtime 缓存，窗口切换只重聚合、不重解析）

    private func load() -> [Snapshot] {
        let path = CursorProvider.mirrorFilePath
        guard let meta = FileMetadata.read(at: path) else { return [] }
        if let c = cache, c.mtime == meta.mtime, c.size == meta.size { return c.snapshots }

        let snaps = Self.parse(mirrorPath: path)
        cache = CacheEntry(mtime: meta.mtime, size: meta.size, snapshots: snaps)
        return snaps
    }

    /// 解析 mirror → 同 `(时间戳, 模型)` 取终值的快照表。
    /// **与 `CursorProvider.aggregate` 的收敛口径必须一致**，否则详情页对不上主行。
    static func parse(mirrorPath: String) -> [Snapshot] {
        guard FileManager.default.fileExists(atPath: mirrorPath) else { return [] }
        let url = URL(fileURLWithPath: mirrorPath)

        var best: [String: Snapshot] = [:]
        try? JSONLReader.forEachLine(at: url) { obj in
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr) else { return }
            let model = (obj["model"] as? String) ?? ""
            let prompt = (obj["prompt_tokens"] as? Int) ?? 0
            let completion = (obj["completion_tokens"] as? Int) ?? 0
            let cacheRead = (obj["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreate = (obj["cache_creation_input_tokens"] as? Int) ?? 0
            let total = prompt + completion + cacheRead + cacheCreate
            if total == 0 { return }

            // Cursor 不区分 5m / 1h 两档缓存写 → 全归 5m 桶（1.25× 档，两档里更常见的那个）。
            let tb = TokenBreakdown(input: prompt, output: completion,
                                    cacheCreate5m: cacheCreate, cacheCreate1h: 0,
                                    cacheRead: cacheRead)
            let key = "\(tsStr)|\(model)"
            if let cur = best[key], cur.tokens.total >= total { return }   // 已有更晚的快照
            best[key] = Snapshot(date: DailyAggregator.dateString(for: ts), model: model, tokens: tb)
        }
        return Array(best.values)
    }
}
