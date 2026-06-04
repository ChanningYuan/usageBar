import Foundation
import usageBarCore

/// WorkBuddy provider（mtime 增量版）
///
/// 数据源：`~/.workbuddy/projects/<工程>/<sessionId>.jsonl`（Claude Code 风格会话记录）
/// 每行一个 JSON，token 在 `type=="message" && role=="assistant"` 行的
/// `providerData.rawUsage` 里（OpenAI 兼容字段 + 扩展）。
///
/// 与 ClaudeCodeProvider 几乎同构，区别：
///   1. 路径 `~/.workbuddy/projects` 而非 `~/.claude/projects`
///   2. usage 在 `providerData.rawUsage`（OpenAI 命名：prompt_tokens / completion_tokens），
///      不是 `message.usage`（Anthropic 命名：input_tokens / output_tokens）
///   3. `timestamp` 是 **epoch 毫秒整数**，不是 ISO 字符串
///
/// 调研依据见 docs/workbuddy-token-research.md（本机 WorkBuddy 4.24.3 实测）。
public struct WorkBuddyProvider: UsageProvider {
    public let id = "workbuddy"
    public let displayName = "WorkBuddy"
    public let iconSymbol = "hammer.circle.fill"
    public let brandColor = "#5B5BD6"

    private var projectsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".workbuddy/projects")
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return [] }

        let jsonlFiles = JSONLReader.findFiles(under: projectsDir) { url in
            url.pathExtension == "jsonl"
        }

        var allRecords: [FileDailyRecord] = []
        for url in jsonlFiles {
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

    /// 解析单个 session jsonl，按日聚合 assistant message 的 rawUsage。
    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]

        try JSONLReader.forEachLine(at: url) { obj in
            guard (obj["type"] as? String) == "message",
                  (obj["role"] as? String) == "assistant",
                  let providerData = obj["providerData"] as? [String: Any],
                  let usage = providerData["rawUsage"] as? [String: Any]
            else { return }

            // timestamp 是 epoch 毫秒（Int），转 Date
            guard let ts = Self.parseEpochMillis(obj["timestamp"]) else { return }

            // OpenAI 兼容命名；rawUsage.prompt_tokens 已含 cache（与 Codex/QoderWork 同档：
            // 主显示数字取 prompt+completion 加总，cache 拆分另有字段但不重复计）
            let prompt = (usage["prompt_tokens"] as? Int) ?? 0
            let completion = (usage["completion_tokens"] as? Int) ?? 0
            let total = prompt + completion
            if total == 0 { return }

            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token)
        }
    }

    /// 把 JSON 里的 epoch 毫秒（可能是 Int / Double / NSNumber）转成 Date。
    private static func parseEpochMillis(_ value: Any?) -> Date? {
        let ms: Double
        if let i = value as? Int {
            ms = Double(i)
        } else if let d = value as? Double {
            ms = d
        } else if let n = value as? NSNumber {
            ms = n.doubleValue
        } else {
            return nil
        }
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }
}
