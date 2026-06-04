import Foundation
import usageBarCore

/// QoderWork provider(main.log 增量 mirror 版,2026-05-28 接入)
///
/// ## 数据流(当前主路径)
/// ```
/// QoderWork main.log (会 rotate,实测保留 ~7 天)
///         ↓ QoderWorkMainLogMirror.runMirror() 增量搬运
/// ~/Library/Application Support/usageBar/qoderwork-mainlog-capture.jsonl
///         ↓ 本 provider 读
/// 按日聚合 token → 菜单栏数字
/// ```
///
/// ## 数据字段
/// 来源:SSE `message_delta` 事件,SDK QueryHandler 解析后落 main.log。
/// 详见 `docs/qoder-work-data-sources.md`。
/// - `timestamp`: ISO 字符串(本地时区,如 `2026-05-28T15:51:00.163+08:00`)
/// - `source`: `qoderwork`
/// - `_via`: `mainlog`
/// - `input_tokens` / `output_tokens`: SSE 协议真值,**精确 2 列**
/// - `cache_creation_input_tokens` / `cache_read_input_tokens`: 固定 0
///   (mainlog 通道协议剥掉了 cache 拆分,只保留 input/output 两列真值)
///
/// ## 零配置
/// 用户零配置,只要打开过 QoderWork 就有数据。
/// 三件套(CLI / IDE / Work)现在都是「简单 + 精确」总 token 路径(Work 缺 cache 拆分,其他两列真值)。
public struct QoderWorkProvider: UsageProvider {
    public let id = "qoder-work"
    public let displayName = "Qoder (Work)"
    public let iconSymbol = "rectangle.stack.badge.plus"
    public let brandColor = "#0E7A5F"
    public var family: String? { "qoder" }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        // Step 1: 跑一次增量 mirror,把 main.log 新增内容搬到自己的 jsonl
        // fast path: main.log 没变化 → 立即返回(几个 stat 调用)
        // 走 serializer actor 串行化:防两次 refresh 重叠时同段增量被 append 两遍(永久虚高)
        _ = await QoderWorkMirrorSerializer.shared.run()

        // Step 2: 读 jsonl + FileMtimeCache(同其他 provider 模式)
        let path = QoderWorkMainLogMirror.capturePath.path
        guard let meta = FileMetadata.read(at: path) else { return [] }

        if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
            return entry.records
        }

        let records = (try? parseFile(url: URL(fileURLWithPath: path))) ?? []
        let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
        await FileMtimeCache.shared.store(entry)
        return records
    }

    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]

        try JSONLReader.forEachLine(at: url) { obj in
            guard (obj["source"] as? String) == "qoderwork",
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }

            let input = (obj["input_tokens"] as? Int) ?? 0
            let output = (obj["output_tokens"] as? Int) ?? 0
            let cacheCreation = (obj["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (obj["cache_read_input_tokens"] as? Int) ?? 0
            let total = input + output + cacheCreation + cacheRead
            if total == 0 { return }

            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token)
        }
    }
}

// MARK: - 历史说明
//
// QoderWork 的 token 来自 main.log 里 SDK 打出的 SSE message_delta 事件
// (input / output 两列真值,不含 cache 拆分),由 QoderWorkMainLogMirror 增量
// mirror 到本地 jsonl,纯本地直读、零配置。
