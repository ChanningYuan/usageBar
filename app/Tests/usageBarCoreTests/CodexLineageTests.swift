import XCTest
import usageBarCore
@testable import usageBarProviders

/// `CodexLineage` 五条规则 + 账本一次性迁移（v0.3.39）。
/// 数字全部取自本机日志实测（调研见 `_notes/docs/0916-Codex统计口径调研/Codex统计口径调研.md`）。
final class CodexLineageTests: XCTestCase {
    private let t0 = ISODateParser.parse("2026-09-12T08:10:00.000Z")!

    private func ev(_ total: Int, last: Int?, cached: Int = 0, lastCached: Int = 0, at: Date? = nil) -> CodexTokenEvent {
        CodexTokenEvent(ts: at ?? t0, total: CodexUsage(input: total, cached: cached),
                        last: last.map { CodexUsage(input: $0, cached: lastCached) })
    }
    private func sum(_ evs: [CodexTokenEvent], baseline: Int = 0) -> Int {
        CodexLineage.deltas(events: evs, baseline: CodexUsage(input: baseline))
            .deltas.reduce(0) { $0 + $1.delta.total }
    }

    // MARK: 规则 4 —— 计数器重启

    /// 续聊老会话后 Codex 0.153 把累计值从 0 重数：本机 7/26 会话 9/12 实录 2.497 亿 → 68,126 → 136,338。
    /// 旧口径（峰值跟踪）把重启后的所有事件都当 0；新口径从头计，一天 407 万不再丢。
    func testCounterRestartStartsNewLineage() {
        let evs = [ev(100, last: 100), ev(250, last: 150),
                   ev(60, last: 60),            // 回落且 == last → 新谱系第一条请求
                   ev(140, last: 80), ev(200, last: 60)]
        XCTAssertEqual(sum(evs), 100 + 150 + 60 + 80 + 60)
        // 对照：旧算法（只有累计值、无 last）在同一序列上只得 250
        XCTAssertEqual(CodexProvider.diffSum(totals: [100, 250, 60, 140, 200], baseline: 0), 250)
    }

    /// 重启后 `maxTotal`（fork 基线）仍是历史最大值，不跟着回落——否则「重启前建的 fork」整段 replay 会被当新增。
    func testMaxTotalIgnoresRestart() {
        let evs = [ev(100, last: 100), ev(250, last: 150), ev(60, last: 60), ev(140, last: 80)]
        let r = CodexLineage.deltas(events: evs, baseline: .zero)
        XCTAssertEqual(r.maxTotal.total, 250)
    }

    // MARK: 规则 5 —— 乱序 / 陈旧事件

    /// 累计值回落但 ≠ last（不是新谱系第一条）→ 跳过本条、状态不动，后面的正常事件照常计。
    func testStaleDipIsSkippedWithoutResetting() {
        let evs = [ev(100, last: 100), ev(250, last: 150),
                   ev(180, last: 30),           // 陈旧快照：180 < 250 且 30 ≠ 180
                   ev(300, last: 50)]
        XCTAssertEqual(sum(evs), 100 + 150 + 50)
    }

    // MARK: 规则 3 —— 子代理继承快照

    /// thread_spawn 文件首条 token_count 是父会话快照（last 全 0）：本机 7/28 实录 103,324,562 起跳。
    /// 旧口径按基线 0 把 1.03 亿整段算成子代理新增；新口径只计自己的 61,839。
    func testInheritedSnapshotOnlyRaisesPeak() {
        let evs = [ev(103_324_562, last: 0),
                   ev(103_354_798, last: 30_236), ev(103_386_401, last: 31_603)]
        XCTAssertEqual(sum(evs), 30_236 + 31_603)
        XCTAssertEqual(CodexLineage.deltas(events: evs, baseline: .zero).maxTotal.total, 103_386_401)
    }

    /// guardian 文件没有快照、首条就是自己的请求（last == total）→ 必须照常计，不能因为是子代理就清零。
    /// （CodexBar 0.58.0 按 `subagent_history_start_ordinal` 排除会把这类真实请求全清掉，本机 1.43 亿。）
    func testSubagentOwnRequestsAreCounted() {
        let evs = [ev(8_677, last: 8_677), ev(19_228, last: 10_551), ev(31_666, last: 12_438)]
        XCTAssertEqual(sum(evs), 31_666)
    }

    // MARK: 规则 1 / 2 —— 峰值门 + min(last, 增幅)

    /// fork 文件：replay 段的 last>0（本机 8/11 实录），只靠累加 last 会把父历史再算一遍；
    /// 父 final 作基线 + 峰值门 → replay 段 0，只计 fork 自己的 41,105（与 CodexForkTests §4.4 同值）。
    func testForkReplaySkippedEvenThoughLastIsPositive() {
        let evs = [ev(40_055, last: 40_055), ev(80_129, last: 40_074),
                   ev(120_216, last: 40_087), ev(160_320, last: 40_104),
                   ev(201_425, last: 41_105)]
        XCTAssertEqual(sum(evs, baseline: 160_320), 41_105)
    }

    /// 同一事件重复落盘（累计值不涨）→ 只计一次。
    func testDuplicateEventCountedOnce() {
        let evs = [ev(100, last: 100), ev(100, last: 100), ev(150, last: 50)]
        XCTAssertEqual(sum(evs), 150)
    }

    /// <0.142 的 last 会虚高（本机实测 8–99%）：增量取 min(last, 累计增幅)，新口径永远不高于旧口径。
    func testInflatedLastIsClampedToAdvance() {
        let evs = [ev(100, last: 100), ev(150, last: 120)]
        XCTAssertEqual(sum(evs), 150)
    }

    /// Codex Desktop「导入」replay 快照（细分全 0 → total 0）夹在中间也不能触发重启。
    func testZeroTotalSnapshotIsIgnoredMidFile() {
        let evs = [ev(100, last: 100), ev(0, last: 0), ev(150, last: 50)]
        XCTAssertEqual(sum(evs), 150)
    }

    /// 缓存命中分量走 last 时也要 ≤ 输入（浅色段不超总长）。
    func testCachedFromLastClampedToInput() {
        let evs = [ev(100, last: 100, cached: 20, lastCached: 20), ev(110, last: 10, cached: 70, lastCached: 50)]
        let r = CodexLineage.deltas(events: evs, baseline: .zero)
        XCTAssertEqual(r.deltas.map(\.delta.cached), [20, 10])
    }

    // MARK: 端到端 —— 真实 JSONL 形状

    /// 用真实行结构写两个 rollout：子代理（继承快照 + 自己两条）与普通会话（续聊重启）。
    func testParseRawEventsEndToEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-lineage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func line(_ ts: String, total: (Int, Int, Int, Int), last: (Int, Int, Int, Int)?) -> String {
            func u(_ v: (Int, Int, Int, Int)) -> String {
                "{\"input_tokens\":\(v.0),\"cached_input_tokens\":\(v.1),\"output_tokens\":\(v.2),\"reasoning_output_tokens\":\(v.3),\"total_tokens\":\(v.0 + v.2)}"
            }
            let lastJSON = last.map(u) ?? "null"
            return "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(u(total)),\"last_token_usage\":\(lastJSON),\"model_context_window\":258400},\"rate_limits\":null}}"
        }
        let meta = "{\"timestamp\":\"2026-07-28T02:26:12.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"child\",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"p\"}}},\"cli_version\":\"0.146.0-alpha.3.1\"}}"
        let sub = [meta,
                   line("2026-07-28T02:26:12.000Z", total: (103_000_000, 90_000_000, 324_562, 1000), last: (0, 0, 0, 0)),
                   line("2026-07-28T02:26:12.000Z", total: (103_030_000, 90_020_000, 324_798, 1010), last: (30_000, 20_000, 236, 10)),
                   line("2026-07-28T02:26:13.000Z", total: (103_061_000, 90_050_000, 325_401, 1020), last: (31_000, 30_000, 603, 10))]
            .joined(separator: "\n") + "\n"
        let subURL = dir.appendingPathComponent("rollout-2026-07-28T10-26-11-child.jsonl")
        try sub.write(to: subURL, atomically: true, encoding: .utf8)

        let normal = ["{\"timestamp\":\"2026-08-26T07:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"p\",\"source\":\"vscode\",\"cli_version\":\"0.146.0-alpha.3.1\"}}",
                      line("2026-08-26T07:04:13.000Z", total: (61_000, 40_000, 500, 0), last: (61_000, 40_000, 500, 0)),
                      line("2026-08-26T07:04:31.000Z", total: (206_000, 180_000, 1_291, 0), last: (145_000, 140_000, 791, 0)),
                      line("2026-09-12T08:10:05.000Z", total: (67_891, 18_816, 235, 0), last: (67_891, 18_816, 235, 0)),
                      line("2026-09-12T08:10:56.000Z", total: (136_025, 86_528, 313, 0), last: (68_134, 67_712, 78, 0))]
            .joined(separator: "\n") + "\n"
        let normalURL = dir.appendingPathComponent("rollout-2026-07-26T21-48-48-p.jsonl")
        try normal.write(to: normalURL, atomically: true, encoding: .utf8)

        let p = CodexProvider()
        let subEvents = p.parseRawEvents(url: subURL)
        XCTAssertEqual(subEvents.count, 3)
        XCTAssertEqual(subEvents[0].last?.total, 0, "继承快照的 last 必须解析成全 0（而不是 nil）")
        let (subDaily, subCached, subMax) = CodexProvider.computeDaily(events: subEvents, baseline: .zero)
        XCTAssertEqual(subDaily.values.reduce(0, +), 30_236 + 31_603)
        XCTAssertEqual(subCached.values.reduce(0, +), 20_000 + 30_000)
        XCTAssertEqual(subMax.total, 103_061_000 + 325_401)

        let nEvents = p.parseRawEvents(url: normalURL)
        let (nDaily, _, nMax) = CodexProvider.computeDaily(events: nEvents, baseline: .zero)
        XCTAssertEqual(nDaily["2026-09-12"], 68_126 + 68_212, "重启后的一天必须补回")
        XCTAssertEqual(nDaily.values.reduce(0, +), 61_500 + 145_791 + 68_126 + 68_212)
        XCTAssertEqual(nMax.total, 207_291, "历史最大不随重启回落")

        // 旧签名（无 last）在同一份普通文件上 = 旧算法：重启后全丢
        let legacy = nEvents.map { (ts: $0.ts, total: $0.total.total, cached: $0.total.cached) }
        let (legacyDaily, _, _, _) = CodexProvider.computeDaily(events: legacy, baseline: 0, cachedBaseline: 0)
        XCTAssertNil(legacyDaily["2026-09-12"])
    }

    // MARK: 账本迁移

    /// 首次运行新算法：只删「源文件仍在」的文件条目（含同文件的 `#fork`，本轮都会重写），
    /// 保留源文件已消失的条目和 `.usagebar-*` 合成条目；标记写进账本本身，重扫完成后才写。
    func testLedgerMigrationKeepsMissingFilesAndSyntheticEntries() async {
        let cache = FileMtimeCache()
        let dir = URL(fileURLWithPath: "/tmp/codex-migrate-\(UUID().uuidString)/sessions")
        let alive = dir.path + "/2026/07/26/rollout-a.jsonl"
        let gone = dir.path + "/2026/07/28/rollout-b.jsonl"
        let rec = [FileDailyRecord(provider: "codex", date: "2026-07-26", token: 1)]
        for path in [alive, gone, alive + "#fork", dir.path + "/.usagebar-detail-ledger"] {
            await cache.store(FileCacheEntry(filePath: path, mtime: Date(), size: 1, records: rec))
        }
        await cache.store(FileCacheEntry(filePath: "/tmp/other/claude.jsonl", mtime: Date(), size: 1,
                                         records: [FileDailyRecord(provider: "claude-code", date: "2026-07-26", token: 1)]))

        let needs = await CodexProvider.needsLedgerMigration(cache: cache, sessionsDir: dir)
        XCTAssertTrue(needs)
        let removed = await CodexProvider.invalidateStaleEntries(
            cache: cache, sessionsDir: dir, existingFileNames: ["rollout-a.jsonl"])
        XCTAssertEqual(removed, 2)
        let paths = Set(await cache.allEntries().map(\.filePath))
        XCTAssertFalse(paths.contains(alive))
        XCTAssertTrue(paths.contains(gone), "源文件已消失的条目无法重算，必须保留")
        XCTAssertFalse(paths.contains(alive + "#fork"), "同文件的 fork 条目也要清，本轮按新 key 重写")
        XCTAssertTrue(paths.contains(dir.path + "/.usagebar-detail-ledger"))
        XCTAssertTrue(paths.contains("/tmp/other/claude.jsonl"))

        // 删条目**不写**标记：首扫中途被杀，下次启动必须重新迁移
        let markerPath = CodexProvider.ledgerAlgoMarkerPath(sessionsDir: dir)
        let premature = await cache.entry(forPath: markerPath)
        XCTAssertNil(premature, "标记只能在重扫完成后写")
        let stillNeeds = await CodexProvider.needsLedgerMigration(cache: cache, sessionsDir: dir)
        XCTAssertTrue(stillNeeds)

        // 重扫完成 → 写标记 → 之后不再迁移
        await CodexProvider.markLedgerMigrated(cache: cache, sessionsDir: dir)
        let marker = await cache.entry(forPath: markerPath)
        XCTAssertEqual(marker?.size, CodexProvider.ledgerAlgoVersion)
        XCTAssertTrue(marker?.records.isEmpty ?? false, "标记条目不能带任何用量")
        let done = await CodexProvider.needsLedgerMigration(cache: cache, sessionsDir: dir)
        XCTAssertFalse(done)
    }
}
