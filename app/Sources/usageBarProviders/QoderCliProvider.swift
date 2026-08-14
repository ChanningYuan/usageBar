import Foundation
import usageBarCore

/// Qoder CLI(npm 主线)provider(mtime 增量版)
///
/// 数据源:`~/.qoder/projects/<encoded-cwd>/<sessionId>.jsonl`(嵌套结构,跟 Claude Code 同款)
/// 字段:`type=="assistant"` + `message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens}`
///
/// 跟 Qoder IDE 不同源:CLI 旧版是 npm Node.js bundle,自己做了 OpenAI→Anthropic 4 列翻译,
/// transcript usage 字段完整;IDE 用的是嵌入式 binary,transcript usage 全 0,
/// 改走 SharedClientCache SQLite。
///
/// ⚠️ 2026-06 起 CLI 也换成 Bun 编译 binary,默认不写 usage(内部 EMPTY_USAGE gate),transcript 四列全 0。
/// 须设环境变量 `QODER_EXPOSE_TOKEN_USAGE=1` 才恢复写真值(本 provider 解析逻辑无需改)。
/// usageBar 通过 `QoderUsageEnvGate` + 设置页横幅引导用户开启,详见 docs/0625-Qoder全家桶token计量/qoder-cli-usage-gate-fix.md。
/// 没开 env 时这里 total==0 的行会被下面自动过滤掉。
///
/// ---------------------------------------------------------------------------
/// 🕐 **新旧两套日志的时间线（改这个文件前先读完，别把两套当成一套）**
/// ---------------------------------------------------------------------------
///
/// Qoder CLI 的 token 落点在 2026-08-05 前后换了一套,两套**并存**,新旧覆盖不同时间段:
///
/// | | **旧源(legacy)** | **新源(current)** |
/// |---|---|---|
/// | 路径 | `~/.qoder/projects/<encoded-cwd>/<sessionId>.jsonl` | `~/.qoder/logs/sessions/<proj>/<session>/segments/*.jsonl` |
/// | 结构 | Claude 同款 transcript,`type=="assistant"` + `message.usage.*` | 诊断事件流,`type=="model.response.completed"` + `data.*_tokens` |
/// | 时间字段 | `timestamp` | `ts` |
/// | 去重键 | `message.id` | `request_id` |
/// | 覆盖时段 | **~2026-08-05 之前**为主(此后仍有持久会话在写,但占比递减) | **2026-08-05 之后**为主 |
/// | 谁在写 | 交互式会话(有持久 transcript) | 全部会话,**含 `--no-session-persistence` 的桥接/非交互调用** |
///
/// **为什么必须双源**:qodercli 1.1.13 起大量调用带 `--print --no-session-persistence`,
/// 这类请求**不写** `projects/`,只在 segments 里留 token 真值。issue #8 报告人本机实测:
/// 8/5 之后 40 个新 segment / 145 条非零 `model.response.completed` 全部漏统。
///
/// ⚠️ **两套有重叠会话,绝不能直接相加**——同一请求可能两边都有,必须按 `request_id`(或等价稳定 ID)
/// 跨源去重后再聚合。详见 docs/0813-数据源下架与issue8修复/。
///
/// 📌 **未来清理点**:旧源是历史包袱。等到「用户账本里 `projects/` 覆盖的时段全部落在展示窗口之外」
/// (或产品上决定不再支持回看那段历史)时,**可以把旧源整支删掉,只留 segments**。
/// 届时要一并处理:① 本文件的旧 transcript 解析分支;② `ClaudeDetailScanner` 里 Qoder CLI 复用的
/// 那条扫描路径;③ 账本里旧源产生的历史 records(保留即可,格式已统一成 FileDailyRecord)。
/// **删旧源前先确认新源能覆盖用户要看的全部时段**,否则历史会凭空少一截。
public struct QoderCliProvider: UsageProvider {
    public let id = "qoder-cli"
    public let displayName = "Qoder CLI"
    public let iconSymbol = "terminal"
    public let brandColor = "#10A37F"
    public var family: String? { "qoder" }

    private var projectsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".qoder/projects")
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        var allRecords: [FileDailyRecord] = []

        // ── 源① 旧 transcript（保留读取，见文件头时间线）──────────────────
        // 先扫它，收两样东西给源② 用：① 见过的 request_id（跨源去重）；② 会话标题（issue #10）。
        var seenRequestIds = Set<String>()
        var sessionTitles: [String: String] = [:]
        if FileManager.default.fileExists(atPath: projectsDir.path) {
            let jsonlFiles = JSONLReader.findFiles(under: projectsDir) { $0.pathExtension == "jsonl" }
            for url in jsonlFiles {
                let path = url.path
                guard let meta = FileMetadata.read(at: path) else { continue }

                // ⚠️ 这一趟必须在 mtime 缓存 lookup **之前**：命中缓存的文件下面会直接 continue，
                // 放到后面会让「标题索引」在文件没变的那些轮里恒为空 —— 表现就是标题时有时无。
                let index = ClaudeDetailScanner.index(url: url)
                seenRequestIds.formUnion(index.requestIds)
                sessionTitles.merge(index.titles) { _, new in new }

                if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
                    allRecords.append(contentsOf: entry.records)
                    continue
                }

                let records = (try? parseFile(url: url)) ?? []
                // v0.3.33：扫盘顺带落明细，详情页改读账本（issue #8 根治）
                let details = ClaudeDetailScanner.detailRecords(
                    url: url, providerId: "qoder-cli", attachSource: false)
                let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size,
                                           records: records, details: details)
                await FileMtimeCache.shared.store(entry)
                allRecords.append(contentsOf: records)
            }
        }

        // ── 源② segments 诊断日志（v0.3.33 新增，issue #8）────────────────
        // `--no-session-persistence` 的桥接/非交互调用只在这里留 token 真值。
        // ⚠️ 跨源去重：同一请求若已被源① 计过（持久化会话两边都写），这里必须跳过，否则翻倍。
        let scan = await QoderCliSegmentStore.shared.scan(under: QoderCliSegmentSource.defaultRoot)
        var segTotals: [String: Int] = [:]
        var segCached: [String: Int] = [:]
        for e in scan.events where e.tokens.total > 0 && !seenRequestIds.contains(e.requestId) {
            segTotals[e.date, default: 0] += e.tokens.total
            segCached[e.date, default: 0] += e.tokens.cacheRead
            // 一请求一条账本 key：同一请求被多个 segment 重放时覆盖同一条、不翻倍；
            // 原始 segment 轮转/删除后历史仍在（与千问办公同款做法）。
            let title = Self.sessionTitle(for: e.sessionId,
                                          transcripts: sessionTitles, roots: scan.projectRoots)
            await FileMtimeCache.shared.store(Self.segmentLedgerEntry(from: e, title: title))
        }
        allRecords.append(contentsOf: segTotals.keys.sorted().map { date in
            FileDailyRecord(provider: id, date: date,
                            token: segTotals[date] ?? 0, cachedToken: segCached[date] ?? 0)
        })

        return allRecords
    }

    /// segment 会话的标题解析顺序（v0.3.34，GitHub issue #10）。
    ///
    /// ① **同 sessionId 的 Qoder transcript 标题** —— 就是 Qoder 自己 `Chat Sessions` 列表里显示的那个
    ///    （自定义改名 > AI 标题 > 首条用户输入，见 `ClaudeDetailScanner.resolvedTitle`）。
    ///    ⚠️ transcript 的 usage 可能全是 0（gate 没开），token 真值在 segments 里——
    ///    所以标题必须走 `ClaudeDetailScanner.index(url:)` 这条不依赖 token 的出口取。
    /// ② **`session.config.loaded` 的工作目录末级名** —— `--no-session-persistence` 的会话
    ///    压根没有 transcript，只能靠它。比 8 位 UUID 强得多。
    /// ③ 空串 —— 交给 `LedgerDetailAggregator` 统一兜底成「(无标题会话)」，别在这里造文案。
    ///
    /// 📌 **不做也不打算做**：从 `input.prompt.*.text_preview` 猜标题（会显示 host 前言/旧历史，
    /// 且可能带出敏感片段，理由见 `QoderCliSegmentSource.projectRoot(in:)`）；
    /// 继承 Claude Code 等宿主会话的标题（要先有 issue #9 的跨 provider 映射，那条已判定暂不修）。
    static func sessionTitle(for sessionId: String,          // internal：被 QoderSessionTitleTests 锁住
                             transcripts: [String: String],
                             roots: [String: String]) -> String {
        if let t = transcripts[sessionId], !t.isEmpty { return t }
        if let root = roots[sessionId] {
            let name = (root as NSString).lastPathComponent
            if !name.isEmpty, name != "/", name != "." { return name }
        }
        return ""
    }

    /// 把一条 segment 请求事件写成账本条目（总量 + 明细各一份）。
    private static func segmentLedgerEntry(from e: QwenWorkUsageEvent, title: String) -> FileCacheEntry {
        let key = QoderCliSegmentSource.defaultRoot
            .appendingPathComponent(".usagebar-request-ledger", isDirectory: true)
            .appendingPathComponent(e.sessionId, isDirectory: true)
            .appendingPathComponent(e.requestId)
            .path
        return FileCacheEntry(
            filePath: key, mtime: e.timestamp, size: e.tokens.total,
            records: [FileDailyRecord(provider: "qoder-cli", date: e.date,
                                      token: e.tokens.total, cachedToken: e.tokens.cacheRead)],
            // v0.3.34：标题由 `sessionTitle(for:transcripts:roots:)` 解析后传进来。
            // ⚠️ 旧注释「segment 无会话标题」只对**这条 token 事件本身**成立，
            // 不代表这个 sessionId 在 Qoder 的持久化 transcript 里没有标题——v0.3.33 把两件事
            // 混为一谈，导致所有 Qoder 会话一律显示「(无标题会话)」（issue #10）。
            // 同一 sessionId 的每条请求写入同一标题；下轮刷新按同 key 覆盖，改名/AI 标题能跟上。
            details: [FileDetailRecord(provider: "qoder-cli", date: e.date,
                                       sessionId: e.sessionId, title: title,
                                       model: e.model, lastActivity: e.timestamp,
                                       tokens: e.tokens)])
    }

    private func parseFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]

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
            dailyCached[date, default: 0] += cacheRead   // 浅色：仅命中读取
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }
}
