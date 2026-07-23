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

        XCTAssertEqual(events.count, 2, "重复 completed、turn.finished、零 token 事件都不应入账")
        XCTAssertEqual(events.map(\.requestId), ["request-1", "request-2"])
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.total }, 200)
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.input }, 107)
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.output }, 23)
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.cacheCreate }, 30)
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.cacheRead }, 40)
    }

    func testMainAndDetailUseExactlyTheSameTokenTotal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let rawEvents = try QwenWorkSegmentParser.files(under: fixture.sessionsRoot)
            .flatMap { try QwenWorkSegmentParser.parseFile(url: $0) }
        XCTAssertEqual(
            rawEvents.reduce(0) { $0 + $1.tokens.total },
            210,
            "第二个 segment 故意重放 request-2，用于证明跨文件去重实际发生"
        )

        let ledger = FileMtimeCache()
        let provider = QwenWorkProvider(
            sessionsRoot: fixture.sessionsRoot,
            ledger: ledger
        )
        let mainRecords = try await provider.fetchDailyRecords()
        let detail = await QwenWorkDetailScanner(
            sessionsRoot: fixture.sessionsRoot,
            projectsRoot: fixture.projectsRoot,
            databasePath: nil
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

        XCTAssertEqual(mainRecords.reduce(0) { $0 + $1.token }, 200)
        XCTAssertEqual(mainRecords.reduce(0) { $0 + $1.cachedToken }, 40)
        XCTAssertEqual(ledgerEntryCount, 2, "两次真实请求应对应两条持久账本记录")
        XCTAssertEqual(ledgerAll?.token, 200, "UsageViewModel 主聚合路径必须拿到千问办公用量")
        XCTAssertEqual(ledgerAll?.cachedToken, 40)
        XCTAssertEqual(detail.tokens.total, 200, "详情 Hero 必须与主列表合计完全一致")
        XCTAssertEqual(detail.tokens.cacheRead, 40)
        XCTAssertEqual(detail.tokens.cacheCreate, 30)
        XCTAssertEqual(detail.models.map(\.modelId), ["qwork-ultimate", "qwork-lite"])
        XCTAssertEqual(detail.sessions.count, 1)
        XCTAssertEqual(detail.sessions.first?.title, "分析千问办公统计")

        // 重复刷新只覆盖同一 request key，账本不得增长或翻倍。
        _ = try await provider.fetchDailyRecords()
        let refreshedDaily = await ledger.allEntries().flatMap(\.records)
        let refreshedEntryCount = await ledger.count()
        XCTAssertEqual(refreshedEntryCount, 2)
        XCTAssertEqual(refreshedDaily.reduce(0) { $0 + $1.token }, 200)
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
                model: "qwork-ultimate", input: 100, output: 20, cacheCreate: 30, cacheRead: 40
            ),
            // 同一 request_id 重复 append：只能计一次。
            completed(
                requestId: "request-1", ts: "2026-07-23T10:00:00.000+08:00",
                model: "qwork-ultimate", input: 100, output: 20, cacheCreate: 30, cacheRead: 40
            ),
            // 整轮汇总副本：与 completed 同算会翻倍。
            #"{"ts":"2026-07-23T10:00:01.000+08:00","type":"turn.finished","request_id":"request-1","data":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}"#,
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
