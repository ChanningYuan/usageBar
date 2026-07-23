import Foundation
import usageBarCore

/// 千问办公（QwenWorkCN）单次模型请求的真实 token 记录。
///
/// 来源：`~/.qwenworkcn/logs/sessions/**/segments/*.jsonl` 中的
/// `type == "model.response.completed"` 事件。`turn.finished` 也带四列 token，
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

            let tokens = TokenBreakdown(
                input: nonNegativeInt(data["input_tokens"]),
                output: nonNegativeInt(data["output_tokens"]),
                cacheCreate5m: nonNegativeInt(data["cache_creation_input_tokens"]),
                cacheCreate1h: 0,
                cacheRead: nonNegativeInt(data["cache_read_input_tokens"])
            )
            // 未打开 QODER_EXPOSE_TOKEN_USAGE 时事件仍存在，但四列全 0；不写入账本噪声。
            guard tokens.total > 0 else { return }

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
/// ## 为什么读 segment，而不是 agents.db / transcript
/// - `agents.db.sub_chats.ext.contextUsageSnapshot` 是会被覆盖的「当前上下文窗口快照」，
///   不是逐轮历史账本，跨会话求和会漏算且语义错误。
/// - `projects/**/*.jsonl` 的 assistant 行是流式分片，同一 `message.id` 会重复；默认还没有 usage。
/// - segment 的 `model.response.completed` 是逐模型请求事件，直接给出 input / output /
///   cache_creation / cache_read 四列，还有 request_id、模型和时间，能稳定去重和拆详情。
///
/// token 真值受 Qoder SDK 共用的 `QODER_EXPOSE_TOKEN_USAGE=1` gate 控制。未开启时历史事件
/// 四列为 0，无法事后恢复；usageBar 的设置页会提示开启，只对之后的新请求生效。
public struct QwenWorkProvider: UsageProvider {
    public let id = "qwen-work"
    public let displayName = "千问办公"
    public let iconSymbol = "sparkles.rectangle.stack"
    public let brandColor = "#39D98A"

    private let sessionsRoot: URL

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwenworkcn/logs/sessions")
    ) {
        self.sessionsRoot = sessionsRoot
    }

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let events = await QwenWorkEventStore.shared.events(under: sessionsRoot)
        return Self.dailyRecords(from: events)
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
