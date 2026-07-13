import Foundation
import usageBarCore

/// Claude Cowork provider（桌面端 Cowork / 本地 agent 模式）
///
/// 数据源：桌面 App 沙箱 home 下的 Claude Code 风格 transcript：
///   `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects/**/*.jsonl`
///
/// Cowork 每个会话在自己的沙箱里跑了一个 Claude Code，于是生成 `.claude/projects/.../<uuid>.jsonl`，
/// 格式与 `message.usage` 字段跟主 `~/.claude/projects` 一模一样。主流工具（ccusage 等）只扫
/// `~/.claude/projects`，故全都漏掉 Cowork —— 这里专门补上。
///
/// 注意：Cowork 用量与 Claude Code/网页聊天**共用同一套餐额度池**，但 Cowork 写的是独立目录，
/// 不会和 ClaudeCodeProvider 重复计数（不同文件、message.id 不重叠）。
///
/// 全部归到单一 provider id "cowork"（Cowork 走 Anthropic 官方直连，message.id 均为 `msg_01...`，
/// 无 sub/api 之分）。解析复用 `ClaudeTranscriptParser`（含 message.id 去重）。
public struct CoworkProvider: UsageProvider {
    public var id: String { "cowork" }
    public var displayName: String { "Claude Cowork" }
    public var iconSymbol: String { "person.2.fill" }
    public var brandColor: String { "#B05730" }  // 比 Claude Code 的 #D97757 更深的陶土色，便于区分
    public var family: String? { "claude" }       // 归入 Claude 组（与 Claude Code 同框）

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions"
        )
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        // 只认 transcript：路径含 /.claude/projects/ 的 jsonl。
        // 排除 audit.jsonl（不在 projects 里、无 usage）和子 agent 的 /subagents/。
        let jsonlFiles = JSONLReader.findFiles(under: root, includeHidden: true) { url in
            url.pathExtension == "jsonl"
                && url.path.contains("/.claude/projects/")
                && !url.path.contains("/subagents/")
        }

        var allRecords: [FileDailyRecord] = []
        for url in jsonlFiles {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }

            if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
                allRecords.append(contentsOf: entry.records)
                continue
            }

            let records = (try? ClaudeTranscriptParser.parse(url: url) { _ in "cowork" }) ?? []
            let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
            await FileMtimeCache.shared.store(entry)
            allRecords.append(contentsOf: records)
        }

        return allRecords
    }
}
