import Foundation
import usageBarCore

/// Codex (OpenAI) provider（mtime 增量 + fork/resume 跨文件去重版）
///
/// 数据源：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// `payload.info.total_token_usage.total_tokens` 是 session 累计值（非增量）。
/// 基础算法：每个 session 内相邻 token_count event 间的差分 = 真实增量，按 event 时间归到日期桶。
///
/// ── 计量口径 ──
/// 用 `total_token_usage.total_tokens`（= input含cached + output），符合 OpenAI Symphony spec。
/// ⚠️ 不要改用 `info.last_token_usage`：每轮 last 把上下文/缓存输入重复计，累加会系统性高估 ~15%。
///
/// ── fork / resume 跨文件去重（2026-06-26 实测定论，取代旧注释的「resume 不接续」结论）──
/// `codex fork` 会新建一个 rollout 文件，**把父会话整段 token 历史 replay 进去**（total 从小爬到父
/// final 再继续）。若每文件都从 0 差分，replay 段会被当新增 → 父会话 token 重复计（同事机实测 2~2.5x）。
/// 修复 = 对 fork 文件用「父会话 final 作差分基线 baseline + 峰值跟踪（prev 只升不降）」，让 replay 段 delta=0。
///
/// 三类文件的判定（优先级严格，见 `fetchDailyRecords`）：
///   1. subagent（首条 `session_meta.source` 是 dict 且含 `subagent` 键）→ 独立计账，**绝不减基线**
///      （baseline=0，短路）。减了会被整段清零。
///   2. fork（首条 `session_meta.forked_from_id` 存在）→ baseline = 父会话 final（信号1，唯一可靠信号）。
///   3. 其余（普通 / UI 重连多 meta / 交互 resume append）→ baseline=0，行为与旧算法逐天一致。
///
/// 实测依据（2026-06-26，本机 + 同事机）：
///   - 交互式 & exec `codex resume` 都只 **append 回原文件**、不新建文件、不写 forked_from_id、total 接续
///     累加（不 replay）→ 不产生重复计。**唯一产生 replay 新文件的是 `codex fork`，且必写 forked_from_id。**
///     故信号1（forked_from_id）单独覆盖全部真实 replay。
///   - 「≥2 个 session_meta」**不能**当 fork 判据：UI 重连会在同一文件写多条同 own-id 的 meta（本机
///     5/11 那个 20.98M 会话有 36 条 meta，单调无重置、forked_from_id 为空），数 meta 会误伤它们。
///   - 信号2（文件内嵌入「别人主文件的 session id」）作为纯跨版本/防同事旧版的兜底，当前 codex 行为下
///     用不到，留作 TODO（实现时务必排在 subagent 短路之后，避免把 subagent 的 spawn 父 id 误当 fork）。
///
/// 已知限制（罕见，保守少算、不虚高）：若先 fork、父会话之后又被 resume 增长，`sessionFinal[父]` 会反映
/// 父 resume 后更大的 final，使该 fork 的新增被压缩。本机无 fork 文件、零影响；记为 TODO（精确解需存
/// 「父在 fork 时刻的 final」快照）。
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

    // MARK: - session_meta 解析

    /// 首条 session_meta 提炼出的去重决策信息
    struct SessionMeta: Sendable {
        let ownId: String
        let forkedFromId: String?
        let isSubagent: Bool
    }

    /// 只读文件头部前几行，取第一条 `session_meta`（mmap，轻量；不读全文件）。
    func readFirstSessionMeta(url: URL) -> SessionMeta? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var start = data.startIndex
        var scanned = 0
        while start < data.endIndex && scanned < 5 {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if nl > start,
               let obj = try? JSONSerialization.jsonObject(with: Data(data[start..<nl])) as? [String: Any],
               (obj["type"] as? String) == "session_meta",
               let payload = obj["payload"] as? [String: Any] {
                let ownId = (payload["id"] as? String) ?? ""
                let forkedFrom = payload["forked_from_id"] as? String
                // subagent：source 是 dict 且含 subagent 键（普通文件 source 是字符串 cli/vscode/exec）
                let isSub = (payload["source"] as? [String: Any])?["subagent"] != nil
                return SessionMeta(ownId: ownId, forkedFromId: forkedFrom, isSubagent: isSub)
            }
            start = nl < data.endIndex ? data.index(after: nl) : data.endIndex
            scanned += 1
        }
        return nil
    }

    // MARK: - 差分核心（纯函数，可测）

    /// 差分核心（文档 §4.4 对拍口径）：baseline 起点 + 峰值跟踪（prev 只升不降）。
    /// 单测用它对拍真实 fork 序列；生产走 `computeDaily`（多一层按日归集）。
    static func diffSum(totals: [Int], baseline: Int) -> Int {
        var prev = baseline
        var sum = 0
        for t in totals {
            sum += max(0, t - prev)
            prev = max(prev, t)  // 峰值跟踪：replay 段从小值再爬回父 final 也不重算
        }
        return sum
    }

    /// 把已收集的 (ts,total) 事件按 baseline+峰值跟踪差分，归到本地日期桶。
    /// 返回 (按日增量, fileFinal=峰值)。非 fork（baseline=0）+ 单调数据时，结果与旧算法逐天一致。
    static func computeDaily(events: [(ts: Date, total: Int)], baseline: Int) -> (daily: [String: Int], fileFinal: Int) {
        let sorted = events.sorted { $0.ts < $1.ts }
        var daily: [String: Int] = [:]
        var prev = baseline
        for ev in sorted {
            let delta = max(0, ev.total - prev)
            prev = max(prev, ev.total)
            if delta > 0 {
                daily[DailyAggregator.dateString(for: ev.ts), default: 0] += delta
            }
        }
        let peak = max(baseline, sorted.map { $0.total }.max() ?? 0)
        return (daily, peak)
    }

    // MARK: - 文件解析

    /// 遍历单个 rollout 文件，收集所有有效 token_count 事件的 (ts,total)。
    /// `info==null` 的 token_count 跳过（不变量2）。
    private func parseRawEvents(url: URL) -> [(ts: Date, total: Int)] {
        var events: [(ts: Date, total: Int)] = []
        try? JSONLReader.forEachLine(at: url) { obj in
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
        return events
    }

    // MARK: - 主入口

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }

        // 文件名 `rollout-{ISO时间}-{uuid}` 字典序 == 时间序 → 父会话一定排在它的 fork 之前，
        // 单遍即可在处理 fork 前把父的 final 填进 sessionFinal。
        let files = JSONLReader.findFiles(under: sessionsDir) { url in
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var sessionFinal: [String: Int] = [:]   // session id → 该会话 peak(=final) total
        var allRecords: [FileDailyRecord] = []

        for url in files {
            let meta = readFirstSessionMeta(url: url)

            // —— baseline 决策（优先级：subagent 短路 > fork 信号1 > 默认0）——
            var baseline = 0
            if let meta {
                if meta.isSubagent {
                    baseline = 0                                  // subagent 绝不减基线
                } else if let parent = meta.forkedFromId {        // 信号1：显式 fork 指针
                    baseline = sessionFinal[parent] ?? 0          // 父缺失 → 0 → 按全量算（自愈）
                }
                // 信号2（嵌入式父 id 兜底）：TODO，当前 codex 行为下用不到（见类型注释）。
            }

            let isFork = baseline > 0
            let path = url.path
            let records: [FileDailyRecord]
            let fileFinal: Int

            if !isFork,
               let m = FileMetadata.read(at: path),
               let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: m.mtime, size: m.size) {
                // 非 fork 文件缓存命中：baseline 恒为 0 且会话单调 → fileFinal = Σrecords
                records = entry.records
                fileFinal = entry.records.reduce(0) { $0 + $1.token }
            } else {
                let events = parseRawEvents(url: url)
                let (daily, ff) = Self.computeDaily(events: events, baseline: baseline)
                records = daily.map { FileDailyRecord(provider: id, date: $0.key, token: $0.value) }
                fileFinal = ff
                // 只缓存非 fork 文件：fork 的 records 依赖跨文件 baseline，父增长会让它失效，故不缓存。
                if !isFork, let m = FileMetadata.read(at: path) {
                    await FileMtimeCache.shared.store(
                        FileCacheEntry(filePath: path, mtime: m.mtime, size: m.size, records: records)
                    )
                }
            }

            if let meta, !meta.ownId.isEmpty {
                sessionFinal[meta.ownId] = max(sessionFinal[meta.ownId] ?? 0, fileFinal)
            }
            allRecords.append(contentsOf: records)
        }

        return allRecords
    }
}
