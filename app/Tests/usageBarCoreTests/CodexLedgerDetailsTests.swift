import XCTest
import usageBarCore
@testable import usageBarProviders

/// v0.3.48：Codex 的明细改成「一个对话文件一条、和主列表的数存在同一条」，并能读 Codex 压缩过的 `.jsonl.zst`。
///
/// 0.3.47 现场：Codex 桌面版 10-16 把 205 个旧日志压缩了，usageBar 读不了，明细又是每轮按现存文件整条覆盖的
/// 一条合成账本 → 主列表 24.85 亿、详情只剩 1.07 亿，79 天对不上。每个用例都真跑刷新，核对主列表 = 明细。
final class CodexLedgerDetailsTests: XCTestCase {
    private var home: URL!
    private var sessions: URL { home.appendingPathComponent("sessions") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-ledger-\(UUID().uuidString)/.codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    // MARK: - 夹具

    /// (累计 input, cached, output) 与单次 (input, cached, output)
    private typealias Usage3 = (Int, Int, Int)
    private typealias Event = (ts: String, total: Usage3, last: Usage3)

    private func rolloutLines(id: String, forkedFrom: String? = nil, events: [Event]) -> String {
        func u(_ v: Usage3) -> String {
            "{\"input_tokens\":\(v.0),\"cached_input_tokens\":\(v.1),\"output_tokens\":\(v.2),\"reasoning_output_tokens\":0,\"total_tokens\":\(v.0 + v.2)}"
        }
        let fork = forkedFrom.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
        let t0 = events.first?.ts ?? "2026-08-11T02:00:00.000Z"
        var lines = ["{\"timestamp\":\"\(t0)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\"vscode\"\(fork)}}",
                     "{\"timestamp\":\"\(t0)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-terra\"}}"]
        for e in events {
            lines.append("{\"timestamp\":\"\(e.ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(u(e.total)),\"last_token_usage\":\(u(e.last))}}}")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    private func writeRollout(stamp: String, id: String, forkedFrom: String? = nil, events: [Event]) throws -> URL {
        let name = "rollout-\(stamp)-\(id).jsonl"
        let url = URL(fileURLWithPath: CodexRolloutFiles.ledgerKey(fileName: name, sessionsDir: sessions)!)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rolloutLines(id: id, forkedFrom: forkedFrom, events: events).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 合法的 zstd 帧：内容原样放进一个「不压缩」块（格式规定的块类型 0）。`truncate` = 模拟压缩到一半被读到。
    private func zstdFrame(_ content: Data, truncate: Bool = false) -> Data {
        var d = Data([0x28, 0xB5, 0x2F, 0xFD, 0xA0])                  // 魔数 + 帧头：单段、4 字节原始大小
        withUnsafeBytes(of: UInt32(content.count).littleEndian) { d.append(contentsOf: $0) }
        let header = UInt32(content.count) << 3 | 1                     // 最后一块、类型 0、块大小
        d.append(contentsOf: [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16 & 0xFF)])
        d.append(truncate ? content.prefix(content.count / 2) : content)
        return d
    }

    /// 像 Codex 桌面版那样把日志压缩：写 `.jsonl.zst`、保留原修改时间、删掉原文件
    @discardableResult
    private func compress(_ url: URL, truncate: Bool = false) throws -> URL {
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        let zst = url.appendingPathExtension("zst")
        try zstdFrame(try Data(contentsOf: url), truncate: truncate).write(to: zst)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: zst.path)
        try FileManager.default.removeItem(at: url)
        return zst
    }

    private func refresh(_ cache: FileMtimeCache) async throws {
        _ = try await CodexProvider(codexHome: home, cache: cache, detailScanner: CodexDetailScanner()).fetchDailyRecords()
    }

    private func mainTotal(_ cache: FileMtimeCache) async -> Int {
        await cache.allEntries().flatMap(\.records).filter { $0.provider == "codex" }.reduce(0) { $0 + $1.token }
    }

    private func detailTotal(_ cache: FileMtimeCache) async -> Int {
        await cache.details(forProvider: "codex").reduce(0) { $0 + $1.tokens.total }
    }

    /// 会话 A：两次请求，累计 2,200（输入 1,900 含缓存 1,200，输出 300）
    private let usageA: [Event] = [
        ("2026-08-11T02:00:05.000Z", (900, 400, 100), (900, 400, 100)),
        ("2026-08-11T02:01:00.000Z", (1900, 1200, 300), (1000, 800, 200)),
    ]
    /// 会话 B：一次请求 500
    private let usageB: [Event] = [
        ("2026-08-12T03:00:05.000Z", (480, 0, 20), (480, 0, 20)),
    ]

    // MARK: - 压缩文件

    /// ⛔ 已入账的文件被 Codex 压缩：主列表、明细都不变，也不会多出一条。
    func testCompressedRolloutKeepsBothNumbers() async throws {
        let a = try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", events: usageA)
        try writeRollout(stamp: "2026-08-12T11-00-00", id: "bbbb", events: usageB)
        let cache = FileMtimeCache()
        try await refresh(cache)
        let entriesBefore = await cache.allEntries().count
        let mainBefore = await mainTotal(cache)
        let detailBefore = await detailTotal(cache)
        XCTAssertEqual(mainBefore, 2_700)
        XCTAssertEqual(detailBefore, 2_700)

        try compress(a)
        try await refresh(cache)
        let mainAfter = await mainTotal(cache)
        let detailAfter = await detailTotal(cache)
        let entriesAfter = await cache.allEntries().count
        XCTAssertEqual(mainAfter, 2_700)
        XCTAssertEqual(detailAfter, 2_700, "0.3.47：明细只剩没压缩的 B（500）")
        XCTAssertEqual(entriesAfter, entriesBefore, "压缩前后是同一个对话，账本不多一条")
    }

    /// ⛔ 新用户：装 usageBar 之前就被压缩的历史也要算进来。
    func testNewUserCountsAlreadyCompressedHistory() async throws {
        try compress(try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", events: usageA))
        let cache = FileMtimeCache()
        try await refresh(cache)
        let main = await mainTotal(cache)
        let detail = await detailTotal(cache)
        XCTAssertEqual(main, 2_200)
        XCTAssertEqual(detail, 2_200)
    }

    /// 压缩到一半被读到（帧不完整）：这次不算，保留上次的数，不拿半截入账。
    func testHalfWrittenCompressedFileKeepsPreviousNumbers() async throws {
        let a = try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", events: usageA)
        let cache = FileMtimeCache()
        try await refresh(cache)
        try compress(a, truncate: true)
        try await refresh(cache)
        let main = await mainTotal(cache)
        let detail = await detailTotal(cache)
        XCTAssertEqual(main, 2_200)
        XCTAssertEqual(detail, 2_200)
    }

    // MARK: - 文件没了

    /// ⛔ 手动删掉对话文件（Codex 没有删除功能，社区通用办法就是删文件）：主列表、明细都还在。
    func testDetailsSurviveDeletedRollout() async throws {
        try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", events: usageA)
        let b = try writeRollout(stamp: "2026-08-12T11-00-00", id: "bbbb", events: usageB)
        let cache = FileMtimeCache()
        try await refresh(cache)
        try FileManager.default.removeItem(at: b)
        try await refresh(cache)
        let main = await mainTotal(cache)
        let detail = await detailTotal(cache)
        XCTAssertEqual(main, 2_700)
        XCTAssertEqual(detail, 2_700, "0.3.47：删掉的对话从详情页消失（2,700 → 2,200）")
    }

    /// ⛔ 原对话文件被删，分叉对话沿用上次按基线算好的数（2026-09-17 实测 0.3.40 主列表 2,500 → 4,700）。
    func testForkKeepsItsNumbersWhenParentIsGone() async throws {
        let parent = try writeRollout(stamp: "2026-08-11T10-00-00", id: "pppp", events: usageA)
        // 分叉：先把原对话的用量照抄一遍（累计爬到 1,900 / 300），再新增 300
        try writeRollout(stamp: "2026-08-11T11-00-00", id: "ffff", forkedFrom: "pppp", events: usageA + [
            ("2026-08-11T03:05:00.000Z", (2150, 1200, 350), (250, 0, 50)),
        ])
        let cache = FileMtimeCache()
        try await refresh(cache)
        let main = await mainTotal(cache)
        XCTAssertEqual(main, 2_500, "原对话 2,200 + 分叉新增 300")

        try FileManager.default.removeItem(at: parent)
        try await refresh(cache)
        let mainAfter = await mainTotal(cache)
        let detailAfter = await detailTotal(cache)
        XCTAssertEqual(mainAfter, 2_500)
        XCTAssertEqual(detailAfter, 2_500)
    }

    // MARK: - 从旧账本升级

    /// 0.3.47 的账本：主列表条目没有明细、另有一条整份合成明细。升级后重读补上明细，删掉旧的合成条目，不重复计。
    func testUpgradeFromWholeLedgerDetails() async throws {
        let a = try writeRollout(stamp: "2026-08-11T10-00-00", id: "aaaa", events: usageA)
        let cache = FileMtimeCache()
        let meta = FileMetadata.read(at: a.path)!
        await cache.store(FileCacheEntry(filePath: a.path, mtime: meta.mtime, size: meta.size,
                                         records: [FileDailyRecord(provider: "codex", date: "2026-08-11", token: 2_200)]))
        let legacy = CodexProvider.legacyDetailLedgerPath(sessionsDir: sessions)
        await cache.store(FileCacheEntry(filePath: legacy, mtime: Date(), size: 1, records: [], details: [
            FileDetailRecord(provider: "codex", date: "2026-08-11", sessionId: "aaaa", title: "", model: "gpt-5.6-terra",
                             lastActivity: Date(), tokens: TokenBreakdown(input: 700, output: 300, cacheRead: 1_200)),
        ]))

        try await refresh(cache)
        let legacyEntry = await cache.entry(forPath: legacy)
        let main = await mainTotal(cache)
        let detail = await detailTotal(cache)
        let fileDetails = await cache.entry(forPath: a.path)?.details.count ?? 0
        XCTAssertNil(legacyEntry, "旧的整份合成明细要删掉")
        XCTAssertEqual(main, 2_200)
        XCTAssertEqual(detail, 2_200, "明细不能和旧合成条目叠成双份")
        XCTAssertGreaterThan(fileDetails, 0, "旧条目没有明细 → 重读一次补上")
    }
}
