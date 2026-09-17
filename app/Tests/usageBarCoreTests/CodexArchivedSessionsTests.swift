import XCTest
import usageBarCore
@testable import usageBarProviders

/// v0.3.40：Codex 归档对话（`~/.codex/archived_sessions/`）计入统计，且归档 / 取消归档来回挪不重复、不丢。
/// 背景见 `CodexRolloutFiles` 文件头。每个用例都用临时 `.codex` 目录 + 独立账本实例，不碰真实数据。
final class CodexArchivedSessionsTests: XCTestCase {
    private var home: URL!
    private var sessions: URL { home.appendingPathComponent("sessions") }
    private var archived: URL { home.appendingPathComponent("archived_sessions") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-archived-\(UUID().uuidString)/.codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    // MARK: - 夹具

    /// (累计 input, cached, output) 与单次 (input, cached, output)
    private typealias Usage3 = (Int, Int, Int)

    /// 写一个真实行结构的 rollout 文件，返回路径。`dir` 为 nil 时放进它文件名日期对应的 sessions 子目录。
    @discardableResult
    private func writeRollout(stamp: String, id: String, in dir: URL? = nil, forkedFrom: String? = nil,
                              events: [(ts: String, total: Usage3, last: Usage3)]) throws -> URL {
        let name = "rollout-\(stamp)-\(id).jsonl"
        let target: URL
        if let dir {
            target = dir
        } else {
            target = URL(fileURLWithPath: CodexRolloutFiles.ledgerKey(fileName: name, sessionsDir: sessions)!)
                .deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        func u(_ v: Usage3) -> String {
            "{\"input_tokens\":\(v.0),\"cached_input_tokens\":\(v.1),\"output_tokens\":\(v.2),\"reasoning_output_tokens\":0,\"total_tokens\":\(v.0 + v.2)}"
        }
        let fork = forkedFrom.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
        var lines = ["{\"timestamp\":\"\(events.first?.ts ?? "2026-08-11T02:00:00.000Z")\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\"vscode\",\"cli_version\":\"0.153.4\"\(fork)}}",
                     "{\"timestamp\":\"\(events.first?.ts ?? "2026-08-11T02:00:00.000Z")\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-terra\"}}"]
        for e in events {
            lines.append("{\"timestamp\":\"\(e.ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(u(e.total)),\"last_token_usage\":\(u(e.last))},\"rate_limits\":null}}")
        }
        let url = target.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func move(_ url: URL, to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)   // 同卷 rename：mtime 不变，与 Codex 归档一致
        return dest
    }

    private func ledgerTotal(_ cache: FileMtimeCache) async -> Int {
        await cache.allEntries().flatMap(\.records).filter { $0.provider == "codex" }.reduce(0) { $0 + $1.token }
    }

    private func detailTotal(_ cache: FileMtimeCache, session: String? = nil) async -> Int {
        await cache.details(forProvider: "codex")
            .filter { session == nil || $0.sessionId == session }
            .reduce(0) { $0 + $1.input + $1.cacheRead + $1.output }
    }

    /// 会话 A：两次请求，累计 2,200（输入 1,900 含缓存 1,200，输出 300）
    private let usageA: [(ts: String, total: Usage3, last: Usage3)] = [
        ("2026-08-11T02:00:05.000Z", (900, 400, 100), (900, 400, 100)),
        ("2026-08-11T02:01:00.000Z", (1900, 1200, 300), (1000, 800, 200)),
    ]
    /// 会话 B：一次请求 500
    private let usageB: [(ts: String, total: Usage3, last: Usage3)] = [
        ("2026-08-12T03:00:05.000Z", (480, 0, 20), (480, 0, 20)),
    ]

    // MARK: - 账本 key 与文件清单

    func testLedgerKeyComesFromFileNameDate() {
        let s = URL(fileURLWithPath: "/x/.codex/sessions")
        XCTAssertEqual(CodexRolloutFiles.ledgerKey(fileName: "rollout-2026-08-11T21-17-10-019ff0f8.jsonl", sessionsDir: s),
                       "/x/.codex/sessions/2026/08/11/rollout-2026-08-11T21-17-10-019ff0f8.jsonl")
        XCTAssertNil(CodexRolloutFiles.ledgerKey(fileName: "rollout-latest.jsonl", sessionsDir: s))
        XCTAssertNil(CodexRolloutFiles.ledgerKey(fileName: "rollout-2026-8-11T21-17-10-x.jsonl", sessionsDir: s))
        XCTAssertEqual(CodexRolloutFiles.archivedDir(forSessions: s).path, "/x/.codex/archived_sessions")
    }

    /// 两处都有同名文件只取一份（修改时间新的那份），只在归档里的也列出来；按文件名排序。
    func testListMergesBothDirsAndDedupesByFileName() throws {
        let b = try writeRollout(stamp: "2026-08-12T11-00-00", id: "bbbb", events: usageB)
        try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", in: archived, events: usageA)
        let staleCopy = archived.appendingPathComponent(b.lastPathComponent)
        try FileManager.default.copyItem(at: b, to: staleCopy)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: staleCopy.path)

        let files = CodexRolloutFiles.list(sessionsDir: sessions)
        XCTAssertEqual(files.map { $0.url.lastPathComponent },
                       ["rollout-2026-08-11T10-00-00-aaaa.jsonl", "rollout-2026-08-12T11-00-00-bbbb.jsonl"])
        XCTAssertTrue(files[0].url.path.contains("/archived_sessions/"))
        XCTAssertFalse(files[1].url.path.contains("/archived_sessions/"), "同名两份时取修改时间新的那份")
        XCTAssertEqual(files[0].ledgerKey, sessions.path + "/2026/08/11/rollout-2026-08-11T10-00-00-aaaa.jsonl",
                       "归档文件的账本 key 还原成它在 sessions 里的路径")
    }

    // MARK: - 端到端（账本 + 明细）

    /// 归档、取消归档、两处残留同名文件，主列表与详情页合计始终不变。
    func testArchiveAndUnarchiveNeverDoubleCountOrLose() async throws {
        let a = try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", events: usageA)
        let b = try writeRollout(stamp: "2026-08-12T11-00-00", id: "bbbb", events: usageB)
        let cache = FileMtimeCache()
        let p = CodexProvider(codexHome: home, cache: cache, detailScanner: CodexDetailScanner())

        _ = try await p.fetchDailyRecords()
        var ledger = await ledgerTotal(cache); var detail = await detailTotal(cache)
        XCTAssertEqual(ledger, 2_700); XCTAssertEqual(detail, 2_700)

        let archivedA = try move(a, to: archived)                                   // 归档
        _ = try await p.fetchDailyRecords()
        ledger = await ledgerTotal(cache); detail = await detailTotal(cache)
        XCTAssertEqual(ledger, 2_700, "归档后主列表不能多算一份")
        XCTAssertEqual(detail, 2_700, "归档后详情页不能丢掉这个会话")
        let aDetail = await detailTotal(cache, session: "aaaa")
        XCTAssertEqual(aDetail, 2_200)

        _ = try move(archivedA, to: a.deletingLastPathComponent())                  // 取消归档
        try FileManager.default.copyItem(at: b, to: archived.appendingPathComponent(b.lastPathComponent))  // 残留同名
        _ = try await p.fetchDailyRecords()
        ledger = await ledgerTotal(cache); detail = await detailTotal(cache)
        XCTAssertEqual(ledger, 2_700); XCTAssertEqual(detail, 2_700)
    }

    /// 从没在 sessions 里被扫到过、一直在归档里的对话（甚至根本没有 sessions 目录）也要计入。
    func testSessionArchivedBeforeEverScannedIsCounted() async throws {
        try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", in: archived, events: usageA)
        let cache = FileMtimeCache()
        _ = try await CodexProvider(codexHome: home, cache: cache, detailScanner: CodexDetailScanner()).fetchDailyRecords()
        let ledger = await ledgerTotal(cache); let detail = await detailTotal(cache)
        XCTAssertEqual(ledger, 2_200); XCTAssertEqual(detail, 2_200)
    }

    /// 父会话被归档的 fork：必须拿到父会话的基线，回放的父历史不算进 fork 自己。
    func testForkOfArchivedParentUsesParentBaseline() async throws {
        try writeRollout(stamp: "2026-08-11T10-00-00", id: "parent", in: archived, events: usageA)
        try writeRollout(stamp: "2026-08-11T10-05-00", id: "fork", forkedFrom: "parent", events: [
            ("2026-08-11T02:05:00.000Z", (900, 400, 100), (900, 400, 100)),      // 回放
            ("2026-08-11T02:05:00.000Z", (1900, 1200, 300), (1000, 800, 200)),   // 回放到父 final
            ("2026-08-11T02:06:00.000Z", (2150, 1400, 350), (250, 200, 50)),     // fork 自己的新请求
        ])
        let cache = FileMtimeCache()
        _ = try await CodexProvider(codexHome: home, cache: cache, detailScanner: CodexDetailScanner()).fetchDailyRecords()
        let parent = await detailTotal(cache, session: "parent")
        let fork = await detailTotal(cache, session: "fork")
        let ledger = await ledgerTotal(cache)
        XCTAssertEqual(parent, 2_200)
        XCTAssertEqual(fork, 300, "父会话在归档里也要当基线，否则回放的 2,200 被算成 fork 的新增")
        XCTAssertEqual(ledger, 2_500)
    }

    /// 父会话后出现（fork 先按全量算过一轮）：fork 身份条目写入时要删掉旧的普通条目，不能两条并存。
    func testForkIdentityFlipDoesNotLeaveTwoEntries() async throws {
        try writeRollout(stamp: "2026-08-11T10-05-00", id: "fork", forkedFrom: "parent", events: [
            ("2026-08-11T02:05:00.000Z", (1900, 1200, 300), (1900, 1200, 300)),
            ("2026-08-11T02:06:00.000Z", (2150, 1400, 350), (250, 200, 50)),
        ])
        let cache = FileMtimeCache()
        let p = CodexProvider(codexHome: home, cache: cache, detailScanner: CodexDetailScanner())
        _ = try await p.fetchDailyRecords()
        var ledger = await ledgerTotal(cache)
        XCTAssertEqual(ledger, 2_500, "父会话缺失时 fork 按全量算（自愈口径）")

        try writeRollout(stamp: "2026-08-11T10-00-00", id: "parent", in: archived, events: usageA)
        _ = try await p.fetchDailyRecords()
        ledger = await ledgerTotal(cache)
        let detail = await detailTotal(cache)
        XCTAssertEqual(ledger, 2_200 + 300, "fork 旧的全量条目必须被替换，不能再加一遍")
        XCTAssertEqual(detail, 2_500)
    }

    /// 从 0.3.39 账本升级：那时已被归档的文件，条目按旧算法留着且 key / mtime / size 都对得上——
    /// 不迁移就会直接命中这条旧数。源文件真没了的条目照旧保留。
    func testUpgradeFromV2RecomputesArchivedEntriesAndKeepsDeletedOnes() async throws {
        let a = try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", in: archived, events: usageA)
        try writeRollout(stamp: "2026-08-12T11-00-00", id: "bbbb", events: usageB)
        let m = FileMetadata.read(at: a.path)!
        let cache = FileMtimeCache()
        let keyA = CodexRolloutFiles.ledgerKey(fileName: a.lastPathComponent, sessionsDir: sessions)!
        await cache.store(FileCacheEntry(filePath: keyA, mtime: m.mtime, size: m.size,
                                         records: [FileDailyRecord(provider: "codex", date: "2026-08-11", token: 999)]))
        let deletedKey = sessions.path + "/2026/07/01/rollout-2026-07-01T09-00-00-gone.jsonl"
        await cache.store(FileCacheEntry(filePath: deletedKey, mtime: Date(), size: 1,
                                         records: [FileDailyRecord(provider: "codex", date: "2026-07-01", token: 77)]))
        await cache.store(FileCacheEntry(filePath: CodexProvider.ledgerAlgoMarkerPath(sessionsDir: sessions),
                                         mtime: Date(), size: 2, records: []))

        _ = try await CodexProvider(codexHome: home, cache: cache, detailScanner: CodexDetailScanner()).fetchDailyRecords()
        let ledger = await ledgerTotal(cache)
        XCTAssertEqual(ledger, 2_200 + 500 + 77, "归档文件的旧数要重算成 2,200；已删文件的 77 保留")
        let marker = await cache.entry(forPath: CodexProvider.ledgerAlgoMarkerPath(sessionsDir: sessions))
        XCTAssertEqual(marker?.size, 3)
    }
}
