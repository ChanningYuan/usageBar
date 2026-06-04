import Foundation
import usageBarCore

/// Codex (OpenAI) provider（mtime 增量版）
///
/// 数据源：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// `payload.info.total_token_usage.total_tokens` 是 session 累计值（非增量），
/// 算法：每个 session 内相邻 token_count event 间的差分 = 真实增量，按 event 时间归到日期桶。
///
/// ⚠️ **不要改用 `info.last_token_usage`**：它看似是逐轮增量，但实测(2026-05-29，本机 38
/// 个 rollout 文件全量验证)`sum(last_token_usage) ≈ 1.1~1.9 × final(total_token_usage)`——
/// 因为每轮的 last 把上下文/缓存输入重复计了。累加 last 会系统性高估 ~15%。差分 total 才对。
///
/// ✅ **resume 复核结论(2026-05-29)**：曾担心 `codex resume` 把累计值带进新 rollout 文件
/// (新文件首条 token_count 就是大基线 → 差分 prev=0 会把整段历史当今日增量重算)。本机 38 个
/// 文件验证：**0 个文件首条 total > 10万**(都是 2~4 万的首轮大小)，且 total 全程单调递增 →
/// resume 不接续累计值，当前差分算法正确，无需跨文件 session 状态。若未来 Codex 改了 resume
/// 语义(首条 total 突然变大)需重新评估。
public struct CodexProvider: UsageProvider {
    public let id = "codex"
    public let displayName = "Codex (OpenAI)"
    public let iconSymbol = "bolt.circle.fill"
    public let brandColor = "#10A37F"

    private var sessionsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/sessions")
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }

        let sessionFiles = JSONLReader.findFiles(under: sessionsDir) { url in
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        }

        var allRecords: [FileDailyRecord] = []
        for url in sessionFiles {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }

            if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
                allRecords.append(contentsOf: entry.records)
                continue
            }

            let records = (try? parseFile(url: url)) ?? []
            let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
            await FileMtimeCache.shared.store(entry)
            allRecords.append(contentsOf: records)
        }

        return allRecords
    }

    /// 解析单个 rollout-*.jsonl
    /// 算法：收集所有 token_count event，按 timestamp 升序，相邻差分归到 curr 的日期。
    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        var events: [(ts: Date, total: Int)] = []
        try JSONLReader.forEachLine(at: url) { obj in
            guard let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }
            let total = (usage["total_tokens"] as? Int) ?? 0
            events.append((ts, total))
        }

        events.sort { $0.ts < $1.ts }
        if events.isEmpty { return [] }

        var dailyTotals: [String: Int] = [:]
        var prevTotal = 0
        for ev in events {
            let delta = max(0, ev.total - prevTotal)
            prevTotal = ev.total
            if delta > 0 {
                let date = DailyAggregator.dateString(for: ev.ts)
                dailyTotals[date, default: 0] += delta
            }
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token)
        }
    }
}
