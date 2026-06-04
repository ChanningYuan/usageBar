import Foundation
import usageBarCore

/// 悟空 provider（mtime 增量版）
///
/// 数据源：`~/Library/Application Support/dingtalk-rewind-server/users/*/storage/llm_proxy/requests.jsonl`
/// 字段驼峰：`createdAtMs` ms 时间戳 / `promptTokens` / `completionTokens`
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

    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]
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

            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
        }
        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token)
        }
    }
}
