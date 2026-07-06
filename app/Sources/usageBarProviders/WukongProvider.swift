import Foundation
import usageBarCore

/// 悟空 provider（双源相加版，2026-07-06 接入 0.9.66 新落点）
///
/// ## 0.9.66 换了 token 落点
/// 悟空升级到 **0.9.66** 后，Codex/ACP 对话不再走本地 llm_proxy（改为直连 `maas.xiaoluozi.cn/v1`），
/// 旧 `requests.jsonl` 里只留一条 token 全 0 的 stub（`path="kernel/codex"`），真实 token 改落到：
///   `~/.real/u/*/kernel/codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// 即悟空内置 codex 内核，格式与 Codex CLI 的 `~/.codex/sessions` **完全同款**（逐行事件对象，
/// `payload.type=="token_count"` → `info.total_token_usage.total_tokens` 是 session 累计值）。
/// 与 `~/.codex`（真 Codex CLI）是两个物理隔离目录，不与 `CodexProvider` 串。
///
/// ## 两个数据源（按天相加）
/// - 源 A · 旧 `requests.jsonl` —— 0.9.66 之前的真实历史，冻结档，升级后基本不再增长
///   `~/Library/.../dingtalk-rewind-server/users/*/storage/llm_proxy/requests.jsonl`
///   token 顶层平铺：`total = promptTokens + completionTokens`，`cacheTokens` 是 promptTokens 子集。
///   ⚠️ `cacheTokens` 是 2026-05-18 才加的字段，之前记录整个 key 缺失 → `?? 0` 兜底。
/// - 源 B · 新 codex rollout —— 0.9.66 起的真实 token
///   取 `token_count` 事件的 `total_token_usage`，**累计值 → 必须差分**（见下）按 event 时间归日期桶。
///
/// 两源不重叠、零双算（同事机 2026-07-06 实测）：旧源非零行截止≈升级日，升级后 `requests.jsonl` 的
/// codex stub 行 token=0（被 `total==0` 自动滤掉）；新源只含升级后的 rollout。按天相加零双算。
///
/// ## 为什么源 B 要差分（而非直接取 last / 求和）
/// `total_token_usage.total_tokens` 是 session 累计值（单调递增，同 Codex CLI）。直接把每个 token_count
/// 事件的 total 相加会把累计值重复叠加、严重虚高；只取最后一条虽得 session 总量，但会把**跨午夜会话**
/// 的 token 全堆到最后一条事件那天，令 今日/本周 边界日算错。故复用 `CodexProvider.computeDaily`
/// （baseline+峰值差分）把每 event 增量归到各自日期。实测 FORK=0/SUBAGENT=0 → baseline 恒 0，
/// 是 CodexProvider 差分算法砍掉 fork 分支后的最简形态。
public struct WukongProvider: UsageProvider {
    public let id = "wukong"
    public let displayName = "悟空"
    public let iconSymbol = "figure.run.circle.fill"
    public let brandColor = "#1677FF"

    private var baseDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/dingtalk-rewind-server/users")
    }

    /// 源 B 根目录：悟空内置 codex 的 rollout 落点（0.9.66+）。
    private var realCodexRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".real")
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        var all: [FileDailyRecord] = []
        all += try await legacyRequestsRecords()   // 源 A：0.9.66 前历史（冻结）
        all += await realCodexRecords()             // 源 B：0.9.66 起 codex rollout
        return all
    }

    // MARK: - 源 A · requests.jsonl（0.9.66 前，冻结）

    private func legacyRequestsRecords() async throws -> [FileDailyRecord] {
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

    // MARK: - 源 B · ~/.real/**/kernel/codex/sessions rollout（0.9.66 起，现行）

    private func realCodexRecords() async -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: realCodexRoot.path) else { return [] }

        let files = JSONLReader.findFiles(under: realCodexRoot) { url in
            url.pathExtension == "jsonl"
                && url.lastPathComponent.hasPrefix("rollout-")
                && url.path.contains("/kernel/codex/sessions/")
        }

        var allRecords: [FileDailyRecord] = []
        for url in files {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }

            // FORK=0/SUBAGENT=0 ⇒ baseline 恒 0、会话单调 ⇒ 缓存安全（同 CodexProvider 非 fork 分支）。
            if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
                allRecords.append(contentsOf: entry.records)
                continue
            }

            let events = parseRolloutEvents(url: url)
            let (daily, cachedDaily, _, _) = CodexProvider.computeDaily(
                events: events, baseline: 0, cachedBaseline: 0)
            let records = daily.map { (date, token) in
                FileDailyRecord(provider: id, date: date, token: token, cachedToken: cachedDaily[date] ?? 0)
            }
            await FileMtimeCache.shared.store(
                FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records))
            allRecords.append(contentsOf: records)
        }
        return allRecords
    }

    /// 遍历单个 rollout 文件，收集 token_count 事件的 (ts,total,cached)。
    /// 结构同 CodexProvider.parseRawEvents：`payload.type=="token_count"` → `info.total_token_usage`。
    /// `info==null` 的 token_count 跳过。internal：供回归单测 @testable 调用。
    func parseRolloutEvents(url: URL) -> [(ts: Date, total: Int, cached: Int)] {
        var events: [(ts: Date, total: Int, cached: Int)] = []
        try? JSONLReader.forEachLine(at: url) { obj in
            guard let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }
            let total = (usage["total_tokens"] as? Int) ?? 0
            let cached = (usage["cached_input_tokens"] as? Int) ?? 0   // 命中读取（input 子集）→ 浅色
            events.append((ts, total, cached))
        }
        return events
    }
}
