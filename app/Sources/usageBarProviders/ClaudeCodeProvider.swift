import Foundation
import usageBarCore

public enum ClaudeCodeVariant: Sendable, Equatable {
    /// `message.id` 以 `msg_01` 开头(Anthropic 官方直连，OAuth/Pro/Max 订阅)
    case subscription
    /// `message.id` 以 `msg_vrtx_`(Vertex AI) 或 `msg_bdrk_`(Bedrock) 开头(第三方代理 / 云厂商)
    case api
}

/// Claude Code provider（mtime 增量版）
///
/// 数据源：`~/.claude/projects/*/*.jsonl`（嵌套结构）
/// 订阅/api 共用同一份文件，按 `message.id` 前缀拆。
///
/// 共享 ClaudeJsonlScanner 避免 sub+api 两次扫盘。
public struct ClaudeCodeProvider: UsageProvider {
    public let variant: ClaudeCodeVariant

    public var id: String {
        switch variant {
        case .subscription: return "claude-sub"
        case .api: return "claude-api"
        }
    }

    public var displayName: String {
        switch variant {
        case .subscription: return "Claude Code (订阅)"
        case .api: return "Claude Code (API)"
        }
    }

    public var iconSymbol: String {
        switch variant {
        case .subscription: return "brain.head.profile"
        case .api: return "network"
        }
    }

    public var brandColor: String {
        switch variant {
        case .subscription: return "#D97757"
        case .api: return "#6F4A8A"
        }
    }

    /// 父级分组,Settings 把 sub/api 聚到同一 "Claude Code" Section 头下
    public var family: String? { "claude" }

    public init(variant: ClaudeCodeVariant) {
        self.variant = variant
    }

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let all = await ClaudeJsonlScanner.shared.scan()
        return all.filter { $0.provider == id }
    }
}

// MARK: - 共享扫描器（避免 sub + api 两次扫同一份 jsonl）

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

        let jsonlFiles = JSONLReader.findFiles(under: projectsDir) { url in
            url.pathExtension == "jsonl" && !url.path.contains("/subagents/")
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

    /// 解析单个 jsonl 文件，按 (variant, date) 聚合 token。
    /// 返回的 records 含 claude-sub 和 claude-api 两种 provider。
    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        // 按 message.id 前缀判断 sub / api：
        // - msg_vrtx_ (Vertex) / msg_bdrk_ (Bedrock) → 第三方代理 → claude-api
        // - msg_01... (Anthropic 官方直连) → OAuth/订阅 → claude-sub
        try ClaudeTranscriptParser.parse(url: url) { messageId in
            (messageId.hasPrefix("msg_vrtx_") || messageId.hasPrefix("msg_bdrk_"))
                ? "claude-api" : "claude-sub"
        }
    }
}

// MARK: - 共享 transcript 解析器（Claude Code + Cowork 共用）

/// 解析一个 Claude Code 风格的 jsonl transcript，按 (provider, date) 聚合 token。
///
/// **去重**：同一条 API 响应（`message.id`）在流式落盘时会被写多行，且每行的 usage 数值完全相同
/// （实际只计费一次）。这里按 `message.id` 文件内去重，只计第一次出现。
/// 实测 `message.id` 全局唯一、无跨文件重复，故文件级去重 == 全局去重，且契合按文件的 mtime 缓存。
///
/// `classify`：把 `message.id` 映射到 provider id（Claude Code 按前缀分 sub/api，Cowork 恒为 "cowork"）。
public enum ClaudeTranscriptParser {
    public static func parse(
        url: URL,
        classify: (_ messageId: String) -> String
    ) throws -> [FileDailyRecord] {
        // key = "\(provider)|\(date)", value = total token
        var totals: [String: Int] = [:]
        var seenIds = Set<String>()

        try JSONLReader.forEachLine(at: url) { obj in
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
            totals["\(providerId)|\(date)", default: 0] += total
        }

        return totals.map { (key, token) in
            let parts = key.split(separator: "|", maxSplits: 1)
            return FileDailyRecord(provider: String(parts[0]), date: String(parts[1]), token: token)
        }
    }
}
