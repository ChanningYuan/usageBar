import Foundation
import usageBarCore

/// Qoder CLI 的**新日志源**：`~/.qoder/logs/sessions/**/segments/*.jsonl`（v0.3.33 接入）。
///
/// ## 为什么要有它（GitHub issue #8 症状二）
///
/// qodercli 1.1.13 起，大量调用带 `--print --no-session-persistence`（不保存可恢复会话）。
/// 这类请求**根本不写** `~/.qoder/projects/` 的 transcript，只把逐请求 token 真值写进
/// segments 诊断日志。旧版 usageBar 只扫 transcript，于是这部分用量**全部漏统**——
/// issue 报告人本机实测：8/5 之后 40 个新 segment、145 条非零 `model.response.completed`
/// 一条都没进主列表。
///
/// ## 新旧两套日志的关系（改这里前先读 `QoderCliProvider` 文件头的时间线表）
///
/// - **旧源** `projects/**/*.jsonl`：Claude 同款 transcript，去重键 `message.id`，
///   ~2026-08-05 之前为主，本版**保留读取**（已拍板 1b）。
/// - **新源** `logs/sessions/**/segments/*.jsonl`：事件流，去重键 `request_id`，8/5 之后为主。
///
/// ⚠️ **两套有重叠会话，绝不能直接相加**：同一个持久化会话的同一次请求，transcript 和 segment
/// 里都会出现。合并时按 `request_id` 跨源去重（见 `QoderCliProvider.fetchDailyRecords`）。
///
/// ## 解析口径
///
/// 与千问办公**逐字复用同一个解析器**（`QwenWorkSegmentParser`）——两者都是 Qoder 的 Go 引擎，
/// 千问办公只是 CN 变体（环境变量前缀 `QODERCN_` vs `QODER_`），日志 schema 完全一致：
/// `type == "model.response.completed"`、`ts`、`request_id`、`data.model`、四列 `data.*_tokens`。
/// 整轮汇总事件 `turn.finished` 明确忽略（与逐请求事件相加会双算）。
enum QoderCliSegmentSource {
    /// 新日志源根目录
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/logs/sessions")
    }
}

/// Qoder CLI segments 的按文件缓存 + 跨文件去重（与 `QwenWorkEventStore` 同构，各管各的根目录）。
///
/// 单独一个 actor 而不是复用千问那个：两者根目录不同、provider id 不同，
/// 合一会让缓存 key 冲突且 provider 归属混淆。
actor QoderCliSegmentStore {
    static let shared = QoderCliSegmentStore()

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let events: [QwenWorkUsageEvent]
    }

    private var cache: [String: CacheEntry] = [:]

    /// 读取该根目录下全部 segment 事件，按 (会话, 请求) 跨文件去重。
    ///
    /// 会话重启后可能新增 segment 文件并重放尾部事件，只按单文件去重会虚高，
    /// 故与千问一致：合并后统一去重。
    func events(under root: URL) -> [QwenWorkUsageEvent] {
        var combined: [QwenWorkUsageEvent] = []

        for url in QwenWorkSegmentParser.files(under: root).sorted(by: { $0.path < $1.path }) {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }
            if let cached = cache[path], cached.mtime == meta.mtime, cached.size == meta.size {
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
            .filter { seen.insert("\($0.sessionId)\u{0}\($0.requestId)").inserted }
    }

    func invalidate() { cache.removeAll() }
}
