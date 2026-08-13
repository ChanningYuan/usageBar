import Foundation
import usageBarCore

/// Claude Code provider（mtime 增量版）
///
/// 数据源：`~/.claude/projects/*/*.jsonl`（嵌套结构）。订阅、API、云渠道和中转
/// 都属于同一份 Claude Code 日志；主列表统一聚合，来源只在详情页拆分。
public struct ClaudeCodeProvider: UsageProvider {
    public let id = "claude-code"
    public let displayName = "Claude Code"
    public let iconSymbol = "brain.head.profile"
    public let brandColor = "#D97757"
    public let family: String? = "claude"

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        await ClaudeJsonlScanner.shared.scan()
    }
}

// MARK: - Claude Code 扫描器

public actor ClaudeJsonlScanner {
    public static let shared = ClaudeJsonlScanner()

    /// 2 秒内的二次调用直接复用（refresh 时 sub + api 几乎同时调）
    private let cacheTTL: TimeInterval = 2
    private var lastScanAt: Date?
    private var lastResult: [FileDailyRecord] = []

    public init() {}

    public func scan() async -> [FileDailyRecord] {
        if let t = lastScanAt, Date().timeIntervalSince(t) < cacheTTL {
            return lastResult
        }
        let records = await actuallyScan()
        lastScanAt = Date()
        lastResult = records
        return records
    }

    private func actuallyScan() async -> [FileDailyRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return [] }

        // 含 subagents/（Task 子代理 + ultracode workflow agent 的 transcript）。
        // 它们的 usage 完全独立于父对话、message.id 不跨文件重复（实测 0 重叠），
        // 漏收即漏算 workflow/子代理用量。文件级 dedup 已够，无需跨文件去重。
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
            // v0.3.33：同一次扫盘顺带落**明细**（会话 / 模型 / 5 列拆分）。
            // 详情页从此读账本，源日志被清理或读不到也能展开（issue #8 根治）。
            let details = ClaudeDetailScanner.detailRecords(
                url: url, providerId: "claude-code", attachSource: true)
            let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size,
                                       records: records, details: details)
            await FileMtimeCache.shared.store(entry)
            allRecords.append(contentsOf: records)
        }

        return allRecords
    }

    /// 解析单个 jsonl 文件，统一按 `claude-code` 聚合 token。
    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        try ClaudeTranscriptParser.parse(url: url) { _ in "claude-code" }
    }
}

// MARK: - 共享 transcript 解析器（Claude Code + Cowork 共用）

/// 解析一个 Claude Code 风格的 jsonl transcript，按 (provider, date) 聚合 token。
///
/// **去重**：同一条 API 响应（`message.id`）在流式落盘时会被写多行，且每行的 usage 数值完全相同
/// （实际只计费一次）。这里按 `message.id` 文件内去重，只计第一次出现。
/// 实测 `message.id` 全局唯一、无跨文件重复，故文件级去重 == 全局去重，且契合按文件的 mtime 缓存。
///
/// `classify`：把 `message.id` 映射到 provider id（Claude Code 恒为 `claude-code`，Cowork 恒为 `cowork`）。
public enum ClaudeTranscriptParser {
    /// 预筛子串（0709 spec R3）：目标行顶层 `"type":"assistant"` 必含此串——Claude Code 落盘是
    /// compact JSON（无空格、键序稳定）。内容行恰好含同款文本只是误放行，由结构 guard 兜住。
    /// 若上游格式漂移（出现空格变体），真机对拍会先暴露 → 届时退宽松 needle `assistant`。
    public static let lineNeedle = "\"type\":\"assistant\""

    public static func parse(
        url: URL,
        classify: (_ messageId: String) -> String,
        lineNeedle: String? = ClaudeTranscriptParser.lineNeedle
    ) throws -> [FileDailyRecord] {
        // key = "\(provider)|\(date)", value = total token
        var totals: [String: Int] = [:]
        var cachedTotals: [String: Int] = [:]   // 同 key 的「缓存命中(cache_read)」分量 → 浅色段
        var seenIds = Set<String>()

        try JSONLReader.forEachLine(at: url, lineNeedle: lineNeedle) { obj in
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }

            // 同一 message.id 只计一次（流式重复落盘的多行 usage 完全相同）
            let messageId = (message["id"] as? String) ?? ""
            if !messageId.isEmpty {
                if seenIds.contains(messageId) { return }
                seenIds.insert(messageId)
            }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let total = input + output + cacheCreation + cacheRead
            if total == 0 { return }

            let providerId = classify(messageId)
            let date = DailyAggregator.dateString(for: ts)
            let key = "\(providerId)|\(date)"
            totals[key, default: 0] += total
            cachedTotals[key, default: 0] += cacheRead   // 浅色：仅命中读取；cache_creation 归深色
        }

        return totals.map { (key, token) in
            let parts = key.split(separator: "|", maxSplits: 1)
            return FileDailyRecord(provider: String(parts[0]), date: String(parts[1]),
                                   token: token, cachedToken: cachedTotals[key] ?? 0)
        }
    }
}
