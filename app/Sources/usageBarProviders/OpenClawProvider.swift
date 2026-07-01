import Foundation
import usageBarCore

/// OpenClaw provider（纯本地，mtime 增量）
///
/// OpenClaw 是社区个人 AI Agent（改名链 Clawdbot → Moltbot → OpenClaw，同一项目）。
/// 数据源：`~/.openclaw/agents/<agentId>/sessions/<sessionId>.jsonl`
///   - 旧版兼容路径：`~/.clawdbot/agents`、`~/.moltbot/agents`
///   - 归档变体文件名：`*.jsonl.deleted.<ts>` / `*.jsonl.reset.<ISO>` → glob 用后缀匹配覆盖
///
/// token 在 `type=="message" && message.role=="assistant"` 且带 `usage` 的行。
/// usage 字段为 **camelCase**（区别于 Claude 的 snake_case）：
///   input / output / cacheRead / cacheWrite / totalTokens，外加 cost.total / model / timestamp(ms)
///
/// 实现参考 tokscale `crates/tokscale-core/src/sessions/openclaw.rs`。
/// 与 WorkBuddy/Claude Code 同档：纯本地、不联网、精确。
public struct OpenClawProvider: UsageProvider {
    public let id = "openclaw"
    public let displayName = "OpenClaw"
    public let iconSymbol = "pawprint.circle.fill"
    public let brandColor = "#E8632C"
    public var family: String? { nil }

    /// 三个历史根目录（改名残留），都扫
    private var agentRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".openclaw", ".clawdbot", ".moltbot"].map {
            home.appendingPathComponent("\($0)/agents")
        }
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        var allRecords: [FileDailyRecord] = []

        for root in agentRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            // glob 用 contains(".jsonl") 覆盖 .jsonl / .jsonl.deleted.* / .jsonl.reset.*
            let files = JSONLReader.findFiles(under: root) { url in
                url.lastPathComponent.contains(".jsonl")
            }
            for url in files {
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
        }
        return allRecords
    }

    /// 解析单个 session jsonl，按日聚合 assistant message 的 usage。
    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]

        try JSONLReader.forEachLine(at: url) { obj in
            guard (obj["type"] as? String) == "message",
                  let message = obj["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let usage = obj["usage"] as? [String: Any] ?? message["usage"] as? [String: Any]
            else { return }

            // timestamp 是 epoch 毫秒
            guard let ts = Self.parseEpochMillis(obj["timestamp"] ?? message["timestamp"]) else { return }

            // camelCase 字段；total = input + output + cacheRead + cacheWrite
            let input = (usage["input"] as? Int) ?? 0
            let output = (usage["output"] as? Int) ?? 0
            let cacheRead = (usage["cacheRead"] as? Int) ?? 0
            let cacheWrite = (usage["cacheWrite"] as? Int) ?? 0
            let total = input + output + cacheRead + cacheWrite
            if total == 0 { return }

            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
            dailyCached[date, default: 0] += cacheRead   // 浅色：仅命中读取（cacheWrite 归深色）
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }

    private static func parseEpochMillis(_ value: Any?) -> Date? {
        let ms: Double
        if let i = value as? Int { ms = Double(i) }
        else if let d = value as? Double { ms = d }
        else if let n = value as? NSNumber { ms = n.doubleValue }
        else { return nil }
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }
}
