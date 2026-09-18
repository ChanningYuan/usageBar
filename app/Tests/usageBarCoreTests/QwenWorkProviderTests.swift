import SQLite3
import XCTest
import usageBarCore
@testable import usageBarProviders

final class QwenWorkProviderTests: XCTestCase {
    private let sessionId = "7d08ad9e-c23c-423e-93f9-e3e5677e197f"

    func testSegmentParserCountsCompletedRequestsOnce() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let events = try QwenWorkSegmentParser.parseFile(url: fixture.segment)

        XCTAssertEqual(events.count, 3, "重复 completed 与 turn.finished 不入账；零 token 事件要保留")
        XCTAssertEqual(events.map(\.requestId), ["request-1", "request-2", "request-zero"])

        // ⚠️ 零 token 事件**保留但不计量**：gate 没开时事件就长这样。
        // 留着是因为详情页要靠它的时间戳算会话区间，才能把服务端账单挂回会话
        // （0804 踩过：丢掉它 → gate 开启前那次对话的积分永远匹配不上，Hero 与「按会话」之和对不上）。
        let counted = events.filter { $0.tokens.total > 0 }
        XCTAssertEqual(counted.map(\.requestId), ["request-1", "request-2"])
        XCTAssertEqual(counted.reduce(0) { $0 + $1.tokens.total }, 130)
        XCTAssertEqual(counted.reduce(0) { $0 + $1.tokens.input }, 67)
        XCTAssertEqual(counted.reduce(0) { $0 + $1.tokens.output }, 23)
        XCTAssertEqual(counted.reduce(0) { $0 + $1.tokens.cacheCreate }, 0,
                       "厂商当前不填 cache_creation_input_tokens（2026-08-04 全量扫描实测恒 0）")
        XCTAssertEqual(counted.reduce(0) { $0 + $1.tokens.cacheRead }, 40)
    }

    /// 缓存写要**读真值**，不能写死 0。
    ///
    /// `cache_creation_input_tokens` 字段是**存在**的，只是厂商目前没往里填（本机全量扫描恒 0）。
    /// 写死 0 的话，哪天他们开始填就会静默漏算——这个测试就是那道闸。
    /// 🔸 真的出现非 0 值时，详情页指标区要从 3 块补成 4 块（`ProviderDetailSpec` 的 "qwen-work"），
    ///    否则「总量」不等于三块之和，看起来就是算错了。
    func testCacheCreationIsReadFromLogNotHardcodedToZero() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segmentDir = dir.appendingPathComponent("s").appendingPathComponent(sessionId)
            .appendingPathComponent("segments")
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)
        let segment = segmentDir.appendingPathComponent("segment.jsonl")
        try completed(
            requestId: "req-cc", ts: "2026-08-04T13:08:21.000+08:00",
            model: "qmodel_latest", input: 100, output: 10, cacheCreate: 25, cacheRead: 40
        ).write(to: segment, atomically: true, encoding: .utf8)

        let events = try QwenWorkSegmentParser.parseFile(url: segment)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].tokens.cacheCreate, 25, "日志里有值就必须读进来")
        XCTAssertEqual(events[0].tokens.input, 60, "净输入仍是 input − cache_read")
        XCTAssertEqual(events[0].tokens.total, 60 + 10 + 25 + 40)
    }

    func testMainAndDetailUseExactlyTheSameTokenTotal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let rawEvents = try QwenWorkSegmentParser.files(under: fixture.sessionsRoot)
            .flatMap { try QwenWorkSegmentParser.parseFile(url: $0) }
        XCTAssertEqual(
            rawEvents.reduce(0) { $0 + $1.tokens.total },
            140,
            "第二个 segment 故意重放 request-2，用于证明跨文件去重实际发生"
        )

        let ledger = FileMtimeCache()
        let provider = QwenWorkProvider(
            sessionsRoot: fixture.sessionsRoot,
            ledger: ledger
        )
        let mainRecords = try await provider.fetchDailyRecords()
        let billingStore = QwenWorkBillingStore(
            fileURL: fixture.root.appendingPathComponent("qwen-work-billings.json")
        )
        await billingStore.replace(origin: .billings, with: [
            QwenWorkBillingRecord(
                amount: -14.1835,
                createdAt: ISODateParser.parse("2026-07-23T10:00:00.000+08:00")!,
                source: "网页版",
                detail: "—",
                origin: .billings,
                serverId: nil,
                type: "对话"
            ),
            QwenWorkBillingRecord(
                amount: 100,
                createdAt: ISODateParser.parse("2026-07-23T08:24:41.000+08:00")!,
                source: "—",
                detail: "每日奖励",
                origin: .billings,
                serverId: nil,
                type: "奖励"
            ),
        ])
        let detail = await QwenWorkDetailScanner(
            sessionsRoot: fixture.sessionsRoot,
            projectsRoot: fixture.projectsRoot,
            databasePath: nil,
            billingStore: billingStore
        ).detail(window: .all)

        // UsageViewModel 的真实主列表只聚合 FileMtimeCache.allEntries()；
        // 锁住 provider 必须写账本的副作用，不能只验证 fetch 返回值。
        let ledgerDaily = await ledger.allEntries().flatMap(\.records)
        let ledgerStats = DailyAggregator.aggregate(
            allDailyRecords: ledgerDaily,
            providerIds: ["qwen-work"]
        )
        let ledgerAll = ledgerStats.first {
            $0.provider == "qwen-work" && $0.time == TimeWindow.all.id
        }
        let ledgerEntryCount = await ledger.count()

        XCTAssertEqual(mainRecords.reduce(0) { $0 + $1.token }, 130)
        XCTAssertEqual(mainRecords.reduce(0) { $0 + $1.cachedToken }, 40)
        // 两次真实请求 = 两条**按请求**的账本记录，每条同时存主列表数与明细（v0.3.41）。
        // v0.3.33 那条整份重算的明细合成记录已退役：日志被清理后它会把旧明细覆盖掉。
        let requestEntryCount = await ledger.allEntries().filter { !$0.records.isEmpty }.count
        XCTAssertEqual(requestEntryCount, 2, "两次真实请求应对应两条持久账本记录")
        XCTAssertEqual(ledgerEntryCount, 2, "明细与主列表数同存一条记录，不再有单独的明细记录")
        let detailInLedger = await ledger.details(forProvider: "qwen-work").reduce(0) { $0 + $1.tokens.total }
        XCTAssertEqual(detailInLedger, 130, "账本里的明细合计必须等于主列表合计")
        XCTAssertEqual(ledgerAll?.token, 130, "UsageViewModel 主聚合路径必须拿到千问办公用量")
        XCTAssertEqual(ledgerAll?.cachedToken, 40)
        XCTAssertEqual(detail.tokens.total, 130, "详情 Hero 必须与主列表合计完全一致")
        XCTAssertEqual(detail.tokens.cacheRead, 40)
        XCTAssertEqual(detail.tokens.cacheCreate, 0)
        XCTAssertEqual(detail.cost, 14.1835, accuracy: 0.0001,
                       "周期积分只汇总真实扣减；每日奖励不能抵扣消耗")
        XCTAssertEqual(detail.models.map(\.modelId), ["qwork-ultimate", "qwork-lite"])
        XCTAssertEqual(detail.sessions.count, 1)
        XCTAssertEqual(detail.sessions.first?.title, "分析千问办公统计")

        // 重复刷新只覆盖同一 request key，账本不得增长或翻倍。
        _ = try await provider.fetchDailyRecords()
        let refreshedDaily = await ledger.allEntries().flatMap(\.records)
        let refreshedRequestCount = await ledger.allEntries().filter { !$0.records.isEmpty }.count
        XCTAssertEqual(refreshedRequestCount, 2, "重复刷新覆盖同一 request key，不新增")
        XCTAssertEqual(refreshedDaily.reduce(0) { $0 + $1.token }, 130)
    }

    func testDatabaseSidebarTitleHasHighestPriority() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("agents.db").path

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        guard let database else {
            XCTFail("failed to create sqlite fixture")
            return
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE chats (
            id TEXT PRIMARY KEY,
            name TEXT
        );
        CREATE TABLE sub_chats (
            id TEXT PRIMARY KEY,
            name TEXT,
            chat_id TEXT,
            session_id TEXT,
            updated_at INTEGER
        );
        INSERT INTO chats VALUES ('chat-1', '聊天标题');
        INSERT INTO sub_chats VALUES (
            'sub-1', '数据库侧栏标题', 'chat-1',
            '7d08ad9e-c23c-423e-93f9-e3e5677e197f', 1784800000
        );
        """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

        let metas = QwenWorkDetailScanner.queryDatabaseMetas(path: path)
        XCTAssertEqual(metas[sessionId]?.databaseTitle, "数据库侧栏标题")

        let fallback = QwenWorkSessionMeta(
            firstUserText: "transcript 标题",
            lastActivity: .distantPast
        )
        var merged = fallback
        if let databaseMeta = metas[sessionId] { merged.merge(databaseMeta) }
        XCTAssertEqual(merged.resolvedTitle, "数据库侧栏标题")
    }

    /// v0.3.41：每个请求的明细和主列表数存在同一条账本记录里。千问办公清理旧日志后，明细不能跟着消失；
    /// 旧版本那条整份重算的明细记录要被退役，否则详情页会算两遍。
    /// （2026-09-17 真实账本：日志最早只剩 9/08，8/14 主列表 158,565 / 明细 98,587。）
    func testDetailsSurviveSegmentLogCleanupAndLegacyEntryIsRetired() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let ledger = FileMtimeCache()
        let legacyKey = "usagebar://detail-ledger/qwen-work"
        await ledger.store(FileCacheEntry(
            filePath: legacyKey, mtime: Date(), size: 1, records: [],
            details: [FileDetailRecord(provider: "qwen-work", date: "2026-07-23", sessionId: sessionId,
                                       title: "", model: "qwork-lite", lastActivity: Date(),
                                       tokens: TokenBreakdown(input: 999))]))
        let scanner = QwenWorkDetailScanner(
            sessionsRoot: fixture.sessionsRoot, projectsRoot: fixture.projectsRoot, databasePath: nil)
        let provider = QwenWorkProvider(sessionsRoot: fixture.sessionsRoot, ledger: ledger, detailScanner: scanner)

        func totals() async -> (list: Int, detail: Int) {
            let entries = await ledger.allEntries()
            let list = entries.flatMap(\.records).filter { $0.provider == "qwen-work" }.reduce(0) { $0 + $1.token }
            let detail = await ledger.details(forProvider: "qwen-work").reduce(0) { $0 + $1.tokens.total }
            return (list, detail)
        }

        _ = try await provider.fetchDailyRecords()
        let before = await totals()
        XCTAssertGreaterThan(before.list, 0)
        XCTAssertEqual(before.detail, before.list, "主列表与明细来自同一条记录，必须相等")
        let legacy = await ledger.entry(forPath: legacyKey)
        XCTAssertNil(legacy, "旧的整份明细记录必须退役，否则详情页算两遍")

        // 千问办公清理掉旧日志
        try FileManager.default.removeItem(at: fixture.sessionsRoot)
        await QwenWorkEventStore.shared.invalidate()
        _ = try await provider.fetchDailyRecords()
        let after = await totals()
        XCTAssertEqual(after.list, before.list, "主列表历史保留")
        XCTAssertEqual(after.detail, before.detail, "日志被清理后明细也必须还在")
    }

    /// v0.3.42：旧版本只存了主列表数、没存明细的请求记录（日志已被清理，明细补不出来）要整条删掉，
    /// 主列表与详情页从此一致；0.3.41 起带明细的记录即使日志没了也必须保留。
    func testRecordsOnlyRequestEntriesFromOldVersionsAreRemoved() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ledger = FileMtimeCache()
        let prefix = fixture.sessionsRoot.appendingPathComponent(".usagebar-request-ledger", isDirectory: true)
        let oldKey = prefix.appendingPathComponent("gone-session", isDirectory: true).appendingPathComponent("old-request").path
        await ledger.store(FileCacheEntry(filePath: oldKey, mtime: Date(), size: 999,
            records: [FileDailyRecord(provider: "qwen-work", date: "2026-08-14", token: 999)]))
        let keptKey = prefix.appendingPathComponent("gone-session", isDirectory: true).appendingPathComponent("kept-request").path
        let keptDetail = FileDetailRecord(provider: "qwen-work", date: "2026-09-10", sessionId: "gone-session", title: "",
                                          model: "qwork-lite", lastActivity: Date(), tokens: TokenBreakdown(input: 50))
        await ledger.store(FileCacheEntry(filePath: keptKey, mtime: Date(), size: 50,
            records: [FileDailyRecord(provider: "qwen-work", date: "2026-09-10", token: 50)], details: [keptDetail]))
        let unrelatedKey = "/tmp/other-provider/\(UUID().uuidString).jsonl"
        await ledger.store(FileCacheEntry(filePath: unrelatedKey, mtime: Date(), size: 1,
            records: [FileDailyRecord(provider: "claude-code", date: "2026-08-14", token: 7)]))

        let scanner = QwenWorkDetailScanner(
            sessionsRoot: fixture.sessionsRoot, projectsRoot: fixture.projectsRoot, databasePath: nil)
        _ = try await QwenWorkProvider(sessionsRoot: fixture.sessionsRoot, ledger: ledger, detailScanner: scanner)
            .fetchDailyRecords()

        let removed = await ledger.entry(forPath: oldKey)
        let kept = await ledger.entry(forPath: keptKey)
        let unrelated = await ledger.entry(forPath: unrelatedKey)
        XCTAssertNil(removed, "只有主列表数、没有明细的旧记录必须删掉")
        XCTAssertNotNil(kept, "带明细的记录（日志没了也一样）必须保留")
        XCTAssertNotNil(unrelated, "别的来源的记录不能动")
        let list = await ledger.allEntries().flatMap(\.records).filter { $0.provider == "qwen-work" }.reduce(0) { $0 + $1.token }
        let detail = await ledger.details(forProvider: "qwen-work").reduce(0) { $0 + $1.tokens.total }
        XCTAssertEqual(list, detail, "删完之后主列表与详情页合计一致")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let sessionsRoot: URL
        let projectsRoot: URL
        let segment: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = temporaryDirectory()
        let sessionsRoot = root.appendingPathComponent("logs/sessions")
        let projectsRoot = root.appendingPathComponent("projects")
        let segmentDir = sessionsRoot
            .appendingPathComponent("workspace")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("segments")
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projectsRoot.appendingPathComponent("workspace"),
            withIntermediateDirectories: true
        )

        let segment = segmentDir.appendingPathComponent("segment.jsonl")
        let segmentLines = [
            completed(
                requestId: "request-1", ts: "2026-07-23T10:00:00.000+08:00",
                model: "qwork-ultimate", input: 100, output: 20, cacheCreate: 0, cacheRead: 40
            ),
            // 同一 request_id 重复 append：只能计一次。
            completed(
                requestId: "request-1", ts: "2026-07-23T10:00:00.000+08:00",
                model: "qwork-ultimate", input: 100, output: 20, cacheCreate: 0, cacheRead: 40
            ),
            // 整轮汇总副本：与 completed 同算会翻倍。
            #"{"ts":"2026-07-23T10:00:01.000+08:00","type":"turn.finished","request_id":"request-1","data":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":40}}"#,
            completed(
                requestId: "request-2", ts: "2026-07-23T10:01:00.000+08:00",
                model: "qwork-lite", input: 7, output: 3, cacheCreate: 0, cacheRead: 0
            ),
            // gate 未开启时的真实形态：事件存在但四列为 0。
            completed(
                requestId: "request-zero", ts: "2026-07-23T10:02:00.000+08:00",
                model: "qwork-lite", input: 0, output: 0, cacheCreate: 0, cacheRead: 0
            ),
            "{malformed-json",
        ]
        try segmentLines.joined(separator: "\n")
            .write(to: segment, atomically: true, encoding: .utf8)

        // 模拟同一会话重启后新 segment 重放上一条 completed。
        let replaySegment = segmentDir.appendingPathComponent("segment-replay.jsonl")
        try completed(
            requestId: "request-2", ts: "2026-07-23T10:01:00.000+08:00",
            model: "qwork-lite", input: 7, output: 3, cacheCreate: 0, cacheRead: 0
        ).write(to: replaySegment, atomically: true, encoding: .utf8)

        let transcript = projectsRoot
            .appendingPathComponent("workspace")
            .appendingPathComponent("\(sessionId).jsonl")
        let transcriptLines = [
            #"{"type":"user","sessionId":"\#(sessionId)","timestamp":"2026-07-23T02:00:00.000Z","cwd":"/tmp/qwen-work","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>internal</system-reminder>"},{"type":"text","text":"分析千问办公统计"}]}}"#,
            #"{"type":"assistant","sessionId":"\#(sessionId)","timestamp":"2026-07-23T02:01:00.000Z","cwd":"/tmp/qwen-work","message":{"role":"assistant","id":"message-1","model":"qwork-ultimate"}}"#,
        ]
        try transcriptLines.joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        return Fixture(
            root: root,
            sessionsRoot: sessionsRoot,
            projectsRoot: projectsRoot,
            segment: segment
        )
    }

    private func completed(
        requestId: String,
        ts: String,
        model: String,
        input: Int,
        output: Int,
        cacheCreate: Int,
        cacheRead: Int
    ) -> String {
        """
        {"ts":"\(ts)","type":"model.response.completed","request_id":"\(requestId)","data":{"model":"\(model)","input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead)}}
        """
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qwen-work-\(UUID().uuidString)", isDirectory: true)
    }
}
