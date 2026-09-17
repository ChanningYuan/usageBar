import Foundation
import usageBarCore

/// Codex（OpenAI 家）provider（mtime 增量 + fork/resume 跨文件去重 + 谱系差分版）
///
/// 数据源：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` + `~/.codex/archived_sessions/rollout-*.jsonl`
/// （v0.3.40 起含归档对话；枚举、去重与账本 key 规则见 `CodexRolloutFiles`）。
/// `payload.info.total_token_usage.total_tokens` 是 session 累计值（非增量）。
/// 差分核心在 `CodexLineage`（v0.3.39 起主行与详情共用；五条规则与实证见该文件头）：
/// 峰值门 / 单次增量 min(last, 增幅) / 子代理继承快照不计 / 计数器重启从头计 / 乱序跳过。
///
/// ── 计量口径（2026-07-10 起与详情页统一）──
/// 事件总量 = `input_tokens`(含cached) + `output_tokens`(含reasoning)。真实事件下恒等于
/// `total_tokens`（本机 1567 事件对拍零偏差），但能天然排除 Codex Desktop「从其他 AI 应用导入」
/// 生成的 replay 快照——那类文件单条 token_count 只有 total_tokens>0、四个细分字段全 0，认
/// total 会把导入的历史会话整段计入导入当天（issue 实测：列表 4.3M vs 详情 1.8M 不一致）。
/// 细分键完全缺失（未知旧格式）才回退 total_tokens。见 `eventTotal`。
/// ⚠️ `info.last_token_usage` 在 <0.142 的日志里会把上下文重复计（本机实测虚高 8–99%），所以
/// 单次增量取 min(last, 累计增幅)，不是直接累加 last。
///
/// ── fork / resume 跨文件去重（2026-06-26 实测定论）──
/// `codex fork` 会新建一个 rollout 文件，**把父会话整段 token 历史 replay 进去**（total 从小爬到父
/// final 再继续）。若每文件都从 0 差分，replay 段会被当新增 → 父会话 token 重复计（同事机实测 2~2.5x）。
/// 修复 = 对 fork 文件用「父会话 final 作差分基线 baseline + 峰值门」，让 replay 段 delta=0。
/// ⚠️ replay 段的 last>0（本机 8/11 fork 文件：42 条 replay 里 41 条 last>0、Σlast 正好等于父 final）
/// ——所以**不能**像 ccusage 那样只累加 last，fork 必须保留父 final 基线。
///
/// 三类文件的判定（优先级严格，见 `fetchDailyRecords`）：
///   1. subagent（首条 `session_meta.source` 是 dict 且含 `subagent` 键）→ baseline=0，**绝不减父基线**
///      （thread_spawn 文件同时带 forked_from_id，减了会被整段清零）。它继承的父快照由
///      `CodexLineage` 规则 3（last 全 0）识别、不计增量。
///   2. fork（首条 `session_meta.forked_from_id` 存在）→ baseline = 父会话历史最大累计（信号1）。
///   3. 其余（普通 / UI 重连多 meta / 交互 resume append）→ baseline=0。
///
/// 实测依据（2026-06-26，本机 + 同事机）：
///   - 交互式 & exec `codex resume` 都只 **append 回原文件**、不新建文件、不写 forked_from_id。
///     0.153 起 resume 会把计数器**从 0 重数**（同一文件内累计值断崖回落），由规则 4 处理。
///   - 「≥2 个 session_meta」**不能**当 fork 判据：UI 重连会在同一文件写多条同 own-id 的 meta（本机
///     5/11 那个 20.98M 会话有 36 条 meta，单调无重置、forked_from_id 为空），数 meta 会误伤它们。
///
/// 已知限制（罕见，保守少算、不虚高）：
///   - 先 fork、父会话之后又被 resume 增长：`sessionFinal[父]` 反映父更大的 final，该 fork 的新增被压缩。
///   - 父会话计数器重启后再 fork：replay 里会重放那次回落，父重启后的那段（本机场景 407 万）会被
///     重复计一次；精确解需按事件序列匹配 replay 边界，暂不做。
///
/// ── 账本迁移（v0.3.39 / v0.3.40）──
/// 旧版本按旧规则算好的条目，文件不变就永远命中 mtime 缓存，新规则永远轮不到。首次运行时把
/// 「源文件仍在（活跃或归档目录里有同名文件）」的 Codex 条目删掉重算一次；源文件已被清理的条目保留原数
/// （无法重算，宁可留旧数也不丢）。见 `needsLedgerMigration` / `invalidateStaleEntries`。
public struct CodexProvider: UsageProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public let iconSymbol = "bolt.circle.fill"
    public let brandColor = "#10A37F"

    /// `~/.codex`（单测注入临时目录）
    private let codexHome: URL
    /// 持久账本（生产 = `.shared`；单测注入独立实例，不碰真实账本）
    private let cache: FileMtimeCache
    private let detailScanner: CodexDetailScanner

    private var sessionsDir: URL { codexHome.appendingPathComponent("sessions") }
    private var archivedDir: URL { CodexRolloutFiles.archivedDir(forSessions: sessionsDir) }

    public init() {
        self.init(codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                  cache: .shared, detailScanner: .shared)
    }

    init(codexHome: URL, cache: FileMtimeCache, detailScanner: CodexDetailScanner) {
        self.codexHome = codexHome
        self.cache = cache
        self.detailScanner = detailScanner
    }

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

    // MARK: - 差分核心（纯函数，可测；实现在 CodexLineage）

    /// 只有累计值序列时的差分（无 last → 无重启检测，行为 = 旧算法「baseline + 峰值跟踪」）。
    /// 单测用它对拍真实 fork 序列；生产走 `computeDaily`。
    static func diffSum(totals: [Int], baseline: Int) -> Int {
        let t0 = Date(timeIntervalSince1970: 0)
        let events = totals.map { CodexTokenEvent(ts: t0, total: CodexUsage(input: $0), last: nil) }
        return CodexLineage.deltas(events: events, baseline: CodexUsage(input: baseline))
            .deltas.reduce(0) { $0 + $1.delta.total }
    }

    /// 旧签名（(ts,total,cached) 三元组、无 last）——保留给回归测试；语义 = 差分模式。
    static func computeDaily(events: [(ts: Date, total: Int, cached: Int)], baseline: Int, cachedBaseline: Int)
        -> (daily: [String: Int], cachedDaily: [String: Int], fileFinal: Int, cachedFinal: Int) {
        let evs = events.map {
            CodexTokenEvent(ts: $0.ts, total: CodexUsage(input: $0.total, cached: $0.cached), last: nil)
        }
        let r = computeDaily(events: evs, baseline: CodexUsage(input: baseline, cached: cachedBaseline))
        return (r.daily, r.cachedDaily, r.maxTotal.total, r.maxTotal.cached)
    }

    /// 把一个文件的事件按 `CodexLineage` 差分后归到本地日期桶。
    /// 返回 (按日增量, 按日缓存命中, 历史最大累计)；`maxTotal` 给 fork 基线用。
    static func computeDaily(events: [CodexTokenEvent], baseline: CodexUsage)
        -> (daily: [String: Int], cachedDaily: [String: Int], maxTotal: CodexUsage) {
        let r = CodexLineage.deltas(events: events, baseline: baseline)
        var daily: [String: Int] = [:]
        var cachedDaily: [String: Int] = [:]
        for d in r.deltas where d.delta.total > 0 {
            let date = DailyAggregator.dateString(for: d.ts)
            daily[date, default: 0] += d.delta.total
            if d.delta.cached > 0 { cachedDaily[date, default: 0] += d.delta.cached }
        }
        return (daily, cachedDaily, r.maxTotal)
    }

    // MARK: - 文件解析

    /// 事件总量口径（类型注释「计量口径」段）：细分键存在时 = input(含cached) + output(含reasoning)，
    /// 与详情页同源；Codex Desktop 导入的 replay 快照（total>0、细分全0）自然归零。
    /// 细分键完全缺失（未知旧格式）才回退 total_tokens，不丢真实用量。
    static func eventTotal(_ usage: [String: Any]) -> Int {
        usageVector(usage).total
    }

    /// `total_token_usage` / `last_token_usage` → 四维向量。与 `eventTotal` 同一套回退规则：
    /// 细分键缺失时把 `total_tokens` 记到 input（total 仍对，cached/output 未知记 0）。
    static func usageVector(_ usage: [String: Any]) -> CodexUsage {
        if usage["input_tokens"] != nil || usage["output_tokens"] != nil {
            return CodexUsage(input: (usage["input_tokens"] as? Int) ?? 0,
                              cached: (usage["cached_input_tokens"] as? Int) ?? 0,
                              output: (usage["output_tokens"] as? Int) ?? 0,
                              reasoning: (usage["reasoning_output_tokens"] as? Int) ?? 0)
        }
        return CodexUsage(input: (usage["total_tokens"] as? Int) ?? 0)
    }

    /// 预筛子串（0709 spec R3）：目标行 `payload.type == "token_count"` 必含此串；
    /// 内容行恰好含 "token_count" 只是误放行多解析一行，由下面的结构 guard 兜住，不影响口径。
    static let lineNeedle = "token_count"

    /// 遍历单个 rollout 文件，收集所有有效 token_count 事件（累计 + 单次增量）。
    /// `info==null` 的 token_count 跳过（不变量2）。`lineNeedle: nil` = 关预筛（对拍测试用）。
    func parseRawEvents(url: URL, lineNeedle: String? = CodexProvider.lineNeedle) -> [CodexTokenEvent] {
        var events: [CodexTokenEvent] = []
        try? JSONLReader.forEachLine(at: url, lineNeedle: lineNeedle) { obj in
            guard let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }
            let last = (info["last_token_usage"] as? [String: Any]).map(Self.usageVector)
            events.append(CodexTokenEvent(ts: ts, total: Self.usageVector(usage), last: last))
        }
        return events
    }

    // MARK: - 账本迁移（v0.3.39 起）

    /// 账本算法版本：1 = 旧「差分 + 峰值跟踪」；2 = `CodexLineage`（继承快照不计 + 重启从头计，v0.3.39）；
    /// 3 = 同时扫 `archived_sessions/`、账本 key 按文件名还原成 sessions 路径（v0.3.40）。
    /// 2 → 3 必须重算：0.3.39 迁移时已被归档的文件「源文件不在 sessions/」→ 条目按旧算法保留了下来，
    /// 现在归档文件被扫到、key 又恰好相同、mtime 没变 → 会直接命中那条旧算法的数。
    static let ledgerAlgoVersion = 3

    /// 标记写在账本自身（合成条目，`size` = 版本号），而且**只在本轮重扫完成后才写**（见 `fetchDailyRecords` 末尾）。
    /// 账本在扫描期间会节流落盘：标记若和删条目同时写，首扫中途被杀就会留下「标记已写、条目没重算」的账本，
    /// 下次启动以为迁过了、旧数永远留着（2026-09-16 验收时抓到过这个中间态）。
    /// 标记放最后：中途被杀 → 下次启动重新走一遍迁移（幂等：删的是「文件仍在」的条目，重扫会补回来）。
    static func ledgerAlgoMarkerPath(sessionsDir: URL) -> String {
        sessionsDir.appendingPathComponent(".usagebar-ledger-algo").path
    }

    /// 本账本是否还没按当前算法版本迁移过。
    static func needsLedgerMigration(cache: FileMtimeCache, sessionsDir: URL) async -> Bool {
        if let m = await cache.entry(forPath: ledgerAlgoMarkerPath(sessionsDir: sessionsDir)),
           m.size >= ledgerAlgoVersion { return false }
        return true
    }

    /// 首次以新算法运行：删掉「源文件仍在」的 Codex 文件条目（含 `#fork`），本轮会按新规则、新 key 重算回来。
    /// 「仍在」按**文件名**判断（`existingFileNames` = 本轮活跃 + 归档目录里的全部 rollout 文件名），
    /// 这样被归档挪走的、以及目录日期与文件名日期不一致而换了 key 的旧条目都会被清掉重算，不会和新条目并存。
    /// 保留源文件已消失的条目（无法重算）与 `.usagebar-*` 合成条目。返回删掉的条数。
    /// **不写标记**——标记由 `markLedgerMigrated` 在重扫完成后写。
    @discardableResult
    static func invalidateStaleEntries(cache: FileMtimeCache, sessionsDir: URL,
                                       existingFileNames: Set<String>) async -> Int {
        let prefix = sessionsDir.path + "/"
        return await cache.remove { e in
            guard e.filePath.hasPrefix(prefix), !e.filePath.hasPrefix(prefix + ".usagebar-") else { return false }
            var path = e.filePath
            if path.hasSuffix("#fork") { path.removeLast("#fork".count) }
            return existingFileNames.contains((path as NSString).lastPathComponent)
        }
    }

    /// 重扫完成后写标记（合成条目，不带任何用量）。
    static func markLedgerMigrated(cache: FileMtimeCache, sessionsDir: URL) async {
        await cache.store(FileCacheEntry(filePath: ledgerAlgoMarkerPath(sessionsDir: sessionsDir),
                                         mtime: Date(), size: ledgerAlgoVersion, records: []))
    }

    // MARK: - 主入口

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir.path) || fm.fileExists(atPath: archivedDir.path) else { return [] }

        // 活跃 + 归档两处，按文件名去重、按文件名排序（字典序 == 时间序 → 父会话一定排在它的 fork 之前，
        // 单遍即可在处理 fork 前把父的 final 填进 sessionFinal；父会话被归档也找得到）。
        let files = CodexRolloutFiles.list(sessionsDir: sessionsDir)

        let migrating = await Self.needsLedgerMigration(cache: cache, sessionsDir: sessionsDir)
        if migrating {
            await Self.invalidateStaleEntries(cache: cache, sessionsDir: sessionsDir,
                                              existingFileNames: Set(files.map { $0.url.lastPathComponent }))
        }

        var sessionFinal: [String: CodexUsage] = [:]   // session id → 历史最大累计（fork 基线用）
        var allRecords: [FileDailyRecord] = []

        for file in files {
            let url = file.url
            let key = file.ledgerKey   // 归档前后同一个 key（见 CodexRolloutFiles）
            let meta = readFirstSessionMeta(url: url)

            // —— baseline 决策（优先级：subagent 短路 > fork 信号1 > 默认0）——
            var baseline = CodexUsage.zero
            if let meta, !meta.isSubagent, let parent = meta.forkedFromId {
                baseline = sessionFinal[parent] ?? .zero   // 父缺失 → 0 → 按全量算（自愈）
            }

            let isFork = baseline.total > 0
            let path = url.path
            let records: [FileDailyRecord]
            let fileFinal: CodexUsage

            if !isFork,
               let m = FileMetadata.read(at: path),
               let entry = await cache.lookup(filePath: key, mtime: m.mtime, size: m.size) {
                // 非 fork 缓存命中：baseline 恒 0 → 用 Σtoken / Σcached 近似历史最大累计
                // （计数器重启过的文件会略大于真值——基线偏大只会让 fork 少算，是保守方向）。
                records = entry.records
                fileFinal = CodexUsage(input: entry.records.reduce(0) { $0 + $1.token },
                                       cached: entry.records.reduce(0) { $0 + $1.cachedToken })
            } else {
                let events = parseRawEvents(url: url)
                let (daily, cachedDaily, maxTotal) = Self.computeDaily(events: events, baseline: baseline)
                records = daily.map { FileDailyRecord(provider: id, date: $0.key, token: $0.value, cachedToken: cachedDaily[$0.key] ?? 0) }
                fileFinal = maxTotal
                if let m = FileMetadata.read(at: path) {
                    if !isFork {
                        // 非 fork：正常按 (mtime,size) 缓存，下轮可命中跳过解析。
                        // 先删同一文件的 fork 身份条目：父会话消失后它从 fork 变回普通文件，两条并存就算两遍。
                        await cache.removeEntry(forPath: key + "#fork")
                        await cache.store(
                            FileCacheEntry(filePath: key, mtime: m.mtime, size: m.size, records: records)
                        )
                    } else {
                        // ⚠️ **fork 文件也必须写账本**（v0.3.33 修）。
                        //
                        // 老行为是「fork 一律不写」——理由是它的 records 依赖跨文件 baseline、父会话增长后会失效。
                        // 但主列表是从 `FileMtimeCache.allEntries()` 聚合的**持久账本**，不写 = 这些 fork 会话的
                        // 用量在主列表里**根本不存在**。本机实测：8-11 一个 fork 会话的 87 万 token 就这么丢了
                        // （列表 18.0M vs 详情 18.9M，正是 issue #8 那类「两个数字打架」，只是方向相反）。
                        //
                        // 修法：写一个**合成 key**（真实路径 + 后缀），且 `mtime` 用当前时刻、`size` 用记录数——
                        // 这样它**永远不会被 `lookup` 命中**（下一轮 fork 分支压根不查缓存），每轮都以最新
                        // baseline 重算并覆盖同一条，既不会失效也不会重复累加。
                        //
                        // 先删同一文件的普通身份条目：父会话后出现（例如 v0.3.40 起能扫到被归档的父会话）时，
                        // 它从普通文件变成 fork，旧的「按全量算」那条若留着就会和这条一起算两遍。
                        await cache.removeEntry(forPath: key)
                        await cache.store(
                            FileCacheEntry(filePath: key + "#fork", mtime: Date(), size: records.count,
                                           records: records)
                        )
                    }
                }
            }

            if let meta, !meta.ownId.isEmpty {
                sessionFinal[meta.ownId] = (sessionFinal[meta.ownId] ?? .zero).componentMax(fileFinal)
            }
            allRecords.append(contentsOf: records)
        }

        // v0.3.33：把**明细**（会话 / 模型 / 5 列）落进持久账本，详情页从此读账本、不再重扫源日志。
        // ⚠️ 与 Claude 系不同，这里必须整体扫完再写：Codex 的 fork 差分基线是跨文件状态，
        // 逐文件独立算会把 replay 段重复计（见 CodexDetailScanner.allDetails 的注释）。
        // 写成一条合成条目（非真实文件路径），源 rollout 被清理后明细仍在。
        let details = await detailScanner.allDetails(providerId: id, root: sessionsDir)
        if !details.isEmpty {
            await cache.store(FileCacheEntry(
                filePath: sessionsDir.appendingPathComponent(".usagebar-detail-ledger").path,
                mtime: Date(), size: details.count,
                records: [], details: details))
        }

        if migrating {
            await Self.markLedgerMigrated(cache: cache, sessionsDir: sessionsDir)
        }
        return allRecords
    }
}
