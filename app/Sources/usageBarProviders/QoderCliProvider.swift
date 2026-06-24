import Foundation
import usageBarCore

/// Qoder CLI(npm 主线)provider(mtime 增量版)
///
/// 数据源:`~/.qoder/projects/<encoded-cwd>/<sessionId>.jsonl`(嵌套结构,跟 Claude Code 同款)
/// 字段:`type=="assistant"` + `message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens}`
///
/// 跟 QoderWork / Qoder IDE 不同源:CLI 旧版是 npm Node.js bundle,自己做了 OpenAI→Anthropic
/// 4 列翻译,transcript usage 字段完整;IDE/QoderWork 用的是嵌入式 binary,transcript usage 全 0,
/// 改走各自的本地持久化数据源(QoderWork 读 main.log mirror,Qoder IDE 读 SharedClientCache SQLite)。
///
/// ⚠️ 2026-06 起 CLI 也换成 Bun 编译 binary,默认不写 usage(内部 EMPTY_USAGE gate),transcript 四列全 0。
/// 须设环境变量 `QODER_EXPOSE_TOKEN_USAGE=1` 才恢复写真值(本 provider 解析逻辑无需改)。
/// usageBar 通过 `QoderUsageEnvGate` + 设置页横幅引导用户开启,详见 docs/qoder-cli-usage-gate-fix.md。
/// 没开 env 时这里 total==0 的行会被下面自动过滤掉。
public struct QoderCliProvider: UsageProvider {
    public let id = "qoder-cli"
    public let displayName = "Qoder (CLI)"
    public let iconSymbol = "terminal"
    public let brandColor = "#10A37F"
    public var family: String? { "qoder" }

    private var projectsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".qoder/projects")
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

    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]

        try JSONLReader.forEachLine(at: url) { obj in
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
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
