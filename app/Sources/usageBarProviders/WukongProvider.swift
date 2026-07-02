import Foundation
import usageBarCore

/// 悟空 provider（mtime 增量版）
///
/// 数据源：`~/Library/Application Support/dingtalk-rewind-server/users/*/storage/llm_proxy/requests.jsonl`
/// 字段驼峰：`createdAtMs` ms 时间戳 / `promptTokens` / `completionTokens` / `cacheTokens`
///
/// token 账本平铺在顶层（OpenAI 口径，无嵌套 usage）：
///   - `total`      = `promptTokens + completionTokens`（实测恒等顶层 `totalTokens`）
///   - `cacheTokens` = 命中读取 = `promptTokens` 子集（内含，同 Codex/qoder-ide）→ 双色浅色段
/// ⚠️ `cacheTokens` 是 2026-05-18 才加的字段，之前的记录整个 key 缺失 → 解析必须 `?? 0` 兜底
/// （本机 8262 条里 6770 条无此字段）。老记录 cachedToken=0，双色自然退化成单色。
public struct WukongProvider: UsageProvider {
    public let id = "wukong"
    public let displayName = "悟空"
    public let iconSymbol = "figure.run.circle.fill"
    public let brandColor = "#1677FF"

    private var baseDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/dingtalk-rewind-server/users")
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: baseDir.path) else { return [] }

        let jsonlFiles = JSONLReader.findFiles(under: baseDir) { url in
            url.lastPathComponent == "requests.jsonl"
                && url.path.contains("/storage/llm_proxy/")
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

    func parseFile(url: URL) throws -> [FileDailyRecord] {   // internal：供回归单测 @testable 调用
        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]
        try JSONLReader.forEachLine(at: url) { obj in
            // 时间戳：ms unix
            let tsMs: Int? = {
                if let i = obj["createdAtMs"] as? Int { return i }
                if let d = obj["createdAtMs"] as? Double { return Int(d) }
                return nil
            }()
            guard let ms = tsMs else { return }
            let ts = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)

            let prompt = (obj["promptTokens"] as? Int) ?? 0
            let completion = (obj["completionTokens"] as? Int) ?? 0
            let total = prompt + completion
            if total == 0 { return }
            // 命中读取 = prompt 子集（内含）；2026-05-18 前无此字段 → ?? 0 兜底
            let cached = (obj["cacheTokens"] as? Int) ?? 0

            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
            dailyCached[date, default: 0] += cached
        }
        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }
}
