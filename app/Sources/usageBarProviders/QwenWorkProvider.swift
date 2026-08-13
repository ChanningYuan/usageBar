import Foundation
import usageBarCore

/// 千问办公（QwenWorkCN）单次模型请求的真实 token 记录。
///
/// 来源：`~/.qwenworkcn/logs/sessions/**/segments/*.jsonl` 中的
/// `type == "model.response.completed"` 事件。`turn.finished` 也带 token 汇总，
/// 但它是整轮汇总，和逐请求事件同时相加会重复统计，所以明确忽略。
struct QwenWorkUsageEvent: Sendable, Equatable {
    let sessionId: String
    let requestId: String
    let timestamp: Date
    let date: String
    let model: String
    let tokens: TokenBreakdown
}

/// 千问办公 segment 的唯一解析口径。
///
/// 主列表和详情页都只调用这里，避免一边读 transcript、一边读 segment 后出现合计不一致。
enum QwenWorkSegmentParser {
    /// 只接受 `<session-id>/segments/*.jsonl`，排除同一 logs 根下的 runs 等其它诊断日志。
    static func files(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return JSONLReader.findFiles(under: root) { url in
            url.pathExtension == "jsonl"
                && url.deletingLastPathComponent().lastPathComponent == "segments"
        }
    }

    static func parseFile(url: URL) throws -> [QwenWorkUsageEvent] {
        let segmentsDir = url.deletingLastPathComponent()
        let sessionId = segmentsDir.deletingLastPathComponent().lastPathComponent
        guard !sessionId.isEmpty else { return [] }

        var events: [QwenWorkUsageEvent] = []
        var seenRequestIds = Set<String>()

        try JSONLReader.forEachLine(at: url) { obj in
            guard (obj["type"] as? String) == "model.response.completed",
                  let requestId = obj["request_id"] as? String, !requestId.isEmpty,
                  let tsString = obj["ts"] as? String,
                  let timestamp = ISODateParser.parse(tsString),
                  let data = obj["data"] as? [String: Any]
            else { return }

            let promptTokens = nonNegativeInt(data["input_tokens"])
            let cacheRead = nonNegativeInt(data["cache_read_input_tokens"])
            let tokens = TokenBreakdown(
                // 千问办公当前走 OpenAI usage 转换：
                // input_tokens = prompt_tokens（已包含 cached_tokens），cache_read = cached_tokens。
                // usageBar 的 TokenBreakdown.input 语义是“净输入”，必须做差，否则一旦命中缓存会双算。
                input: max(0, promptTokens - cacheRead),
                output: nonNegativeInt(data["output_tokens"]),
                // ⚠️ 读真值，别写死 0。`cache_creation_input_tokens` 这个字段**是存在的**，
                // 只是本机 2026-08-04 实测的样本里厂商还没往里填（全 0）。写死 0 的话，
                // 哪天他们开始填就会静默漏算。
                // 🔸 一旦这里真出现非 0 值：详情页指标区要从 3 块补成 4 块
                //    （`ProviderDetailSpec` 里 "qwen-work" 的 metricRows），否则
                //    「总量」会不等于三块之和，用户会以为是算错了。
                cacheCreate5m: nonNegativeInt(data["cache_creation_input_tokens"]),
                cacheCreate1h: 0,
                cacheRead: cacheRead
            )
            // ⚠️ token 全 0 的事件**照样保留**（没开 QODERCN_EXPOSE_TOKEN_USAGE 时就是这样）。
            // 它不进 token 统计（写账本前另行过滤），但它证明「这个会话在这个时刻确实发过请求」——
            // 详情页要靠这些时间点算出会话区间，才能把服务端账单挂回会话。
            // 2026-08-04 踩过：丢掉 0-token 事件 → gate 开启前那次对话的积分永远匹配不上，
            // Hero 总额与「按会话」之和差了 1.2329，看起来就是"数字对不上"。

            // segment 理论上一请求只写一次 completed；仍按 request_id 防御性去重，
            // 避免日志重放/重复 append 导致永久虚高。
            guard seenRequestIds.insert(requestId).inserted else { return }

            let rawModel = (data["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model = rawModel.flatMap { $0.isEmpty ? nil : $0 } ?? "(未知)"
            events.append(QwenWorkUsageEvent(
                sessionId: sessionId,
                requestId: requestId,
                timestamp: timestamp,
                date: DailyAggregator.dateString(for: timestamp),
                model: model,
                tokens: tokens
            ))
        }

        return events
    }

    private static func nonNegativeInt(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return max(0, number.intValue)
    }
}

/// segment 按文件 mtime/size 缓存，但去重在合并所有文件后进行。
///
/// 同一会话重启后可能新增 segment 文件；如果尾部 completed 被重放，只按单文件去重仍会虚高。
/// 主列表与详情页共享这个 store，因此二者不仅共用 parser，也共用跨文件去重后的事件集合。
actor QwenWorkEventStore {
    static let shared = QwenWorkEventStore()

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let events: [QwenWorkUsageEvent]
    }

    private var cache: [String: CacheEntry] = [:]

    func events(under root: URL) -> [QwenWorkUsageEvent] {
        var combined: [QwenWorkUsageEvent] = []

        for url in QwenWorkSegmentParser.files(under: root).sorted(by: { $0.path < $1.path }) {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }
            if let cached = cache[path],
               cached.mtime == meta.mtime, cached.size == meta.size {
                combined.append(contentsOf: cached.events)
                continue
            }

            let parsed = (try? QwenWorkSegmentParser.parseFile(url: url)) ?? []
            cache[path] = CacheEntry(mtime: meta.mtime, size: meta.size, events: parsed)
            combined.append(contentsOf: parsed)
        }

        var seen = Set<String>()
        return combined
            .sorted { $0.timestamp < $1.timestamp }
            .filter { event in
                seen.insert("\(event.sessionId)\u{0}\(event.requestId)").inserted
            }
    }

    func invalidate() {
        cache.removeAll()
    }
}

/// 千问办公 provider。
///
/// ## 日志里到底有哪些 token 字段（2026-08-04 全量扫描实测）
/// `model.response.completed` 与 `turn.finished` 的 data 各自只有这 4 个计量字段：
/// `input_tokens`（**含 cached**）/ `output_tokens` / `cache_read_input_tokens` /
/// `cache_creation_input_tokens`（字段在，本机样本恒 0）。
/// **没有 reasoning / thinking 字段**——Codex、OpenCode 那套"输出⊃思考"的拆分在千问这里不存在，
/// 别照搬。指标区因此只有 3 块。
///
/// ## 为什么读 segment，而不是 agents.db / transcript
/// - `agents.db.sub_chats.ext.contextUsageSnapshot` 是会被覆盖的「当前上下文窗口快照」，
///   不是逐轮历史账本，跨会话求和会漏算且语义错误。
/// - `projects/**/*.jsonl` 的 assistant 行是流式分片，同一 `message.id` 会重复；默认还没有 usage。
/// - segment 的 `model.response.completed` 是逐模型请求事件，给出 prompt / output / cache_read，
///   还有 request_id、模型和时间，能稳定去重和拆详情。当前 OpenAI usage 转换不提供缓存写。
///
/// token 真值受 CN SDK 的 `QODERCN_EXPOSE_TOKEN_USAGE=1` gate 控制。未开启时历史事件
/// 各列为 0，无法事后恢复；usageBar 的设置页会提示开启，只对之后的新请求生效。
public struct QwenWorkProvider: UsageProvider {
    public let id = "qwen-work"
    public let displayName = "千问办公"
    public let iconSymbol = "sparkles.rectangle.stack"
    public let brandColor = "#39D98A"

    private let sessionsRoot: URL
    private let ledger: FileMtimeCache

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwenworkcn/logs/sessions"),
        ledger: FileMtimeCache = .shared
    ) {
        self.sessionsRoot = sessionsRoot
        self.ledger = ledger
    }

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let events = await QwenWorkEventStore.shared.events(under: sessionsRoot)
        // UsageViewModel 的主列表以 FileMtimeCache.allEntries() 为持久账本，
        // provider 返回值只用于调试计时。因此每个真实请求必须同时写入账本。
        //
        // 一请求一 key 有两个好处：
        // 1. 同一 request 被多个 segment 重放时覆盖同一条，不会翻倍；
        // 2. 原始 segment 轮转/删除后，已经发生的历史消耗仍保留。
        // 只有真的记到了 token 才写账本；0-token 事件仅用于会话区间（见 parseFile 的注释）。
        for event in events where event.tokens.total > 0 {
            await ledger.store(Self.ledgerEntry(from: event, sessionsRoot: sessionsRoot))
        }
        // v0.3.33：token 明细落账本（积分不入账本——它来自联网账单且会原地增长，
        // 见 QwenWorkDetailScanner.allDetails 的说明）。
        let details = await QwenWorkDetailScanner.shared.allDetails()
        if !details.isEmpty {
            await ledger.store(FileCacheEntry(
                filePath: "usagebar://detail-ledger/qwen-work", mtime: Date(), size: details.count,
                records: [], details: details))
        }
        return Self.dailyRecords(from: events.filter { $0.tokens.total > 0 })
    }

    private static func ledgerEntry(
        from event: QwenWorkUsageEvent,
        sessionsRoot: URL
    ) -> FileCacheEntry {
        let key = sessionsRoot
            .appendingPathComponent(".usagebar-request-ledger", isDirectory: true)
            .appendingPathComponent(event.sessionId, isDirectory: true)
            .appendingPathComponent(event.requestId)
            .path
        return FileCacheEntry(
            filePath: key,
            mtime: event.timestamp,
            size: event.tokens.total,
            records: [FileDailyRecord(
                provider: "qwen-work",
                date: event.date,
                token: event.tokens.total,
                cachedToken: event.tokens.cacheRead
            )]
        )
    }

    static func dailyRecords(from events: [QwenWorkUsageEvent]) -> [FileDailyRecord] {
        var totals: [String: Int] = [:]
        var cached: [String: Int] = [:]
        for event in events {
            totals[event.date, default: 0] += event.tokens.total
            cached[event.date, default: 0] += event.tokens.cacheRead
        }
        return totals.keys.sorted().map { date in
            FileDailyRecord(
                provider: "qwen-work",
                date: date,
                token: totals[date] ?? 0,
                cachedToken: cached[date] ?? 0
            )
        }
    }
}
