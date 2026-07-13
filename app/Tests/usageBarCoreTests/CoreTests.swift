import XCTest
@testable import usageBarCore

final class StatRecordTests: XCTestCase {
    func testStatRecordCodable() throws {
        let r = StatRecord(provider: "claude-code", time: "today", token: 12345)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(StatRecord.self, from: data)
        XCTAssertEqual(r, decoded)
    }

    func testDailyAggregator() {
        let dailys = [
            FileDailyRecord(provider: "claude-code", date: "2026-05-20", token: 100),
            FileDailyRecord(provider: "claude-code", date: "2026-05-19", token: 200),
            FileDailyRecord(provider: "claude-code", date: "2026-05-01", token: 999),
            FileDailyRecord(provider: "cowork", date: "2026-05-20", token: 50),
        ]
        // 用 2026-05-20 为 now 测试
        let now = DailyAggregator.shanghaiFmtToDate("2026-05-20")
        let result = DailyAggregator.aggregate(
            allDailyRecords: dailys,
            providerIds: ["claude-code", "cowork"],
            now: now
        )
        let ccToday = result.first { $0.provider == "claude-code" && $0.time == "today" }
        XCTAssertEqual(ccToday?.token, 100)

        let ccAll = result.first { $0.provider == "claude-code" && $0.time == "all" }
        XCTAssertEqual(ccAll?.token, 100 + 200 + 999)

        let coworkToday = result.first { $0.provider == "cowork" && $0.time == "today" }
        XCTAssertEqual(coworkToday?.token, 50)
    }

    func testTimeWindowId() {
        XCTAssertEqual(TimeWindow.today.id, "today")
        XCTAssertEqual(TimeWindow.last7Days.id, "last7Days")
        XCTAssertEqual(TimeWindow.all.id, "all")
    }

    /// 持久账本语义:缓存条目对应的源文件即使不存在,allEntries 仍保留它,
    /// 聚合时其 token 仍计入。锁住「会话文件删了 token 不丢」的行为,防回归。
    func testLedgerRetainsRecordsForMissingFile() async {
        let cache = FileMtimeCache()  // 独立实例,不污染 shared 单例
        let ghostPath = "/nonexistent/deleted-session-\(UUID().uuidString).jsonl"
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghostPath))

        await cache.store(FileCacheEntry(
            filePath: ghostPath,
            mtime: Date(),
            size: 123,
            records: [FileDailyRecord(provider: "codex", date: "2026-05-01", token: 777)]
        ))

        // 账本读 allEntries(而非现存文件)→ 已删文件的 record 仍在
        let allDaily = await cache.allEntries().flatMap { $0.records }
        let computed = DailyAggregator.aggregate(
            allDailyRecords: allDaily,
            providerIds: ["codex"]
        )
        let codexAll = computed.first { $0.provider == "codex" && $0.time == "all" }
        XCTAssertEqual(codexAll?.token, 777, "源文件不存在,账本仍应保留其历史 token")
    }
}

// 测试 helper：用日期字符串构造 Date（本机时区 00:00:00，与生产 DailyAggregator 一致）
extension DailyAggregator {
    static func shanghaiFmtToDate(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: s) ?? Date()
    }
}
