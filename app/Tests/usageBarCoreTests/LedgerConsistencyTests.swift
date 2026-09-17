import XCTest
import usageBarCore
@testable import usageBarProviders

/// v0.3.41：「主列表合计 = 明细合计」要靠构造保证，不能靠两套解析碰巧一致。
///
/// 2026-09-17 真实账本逐来源核对，Claude Code 5 个文件主列表与明细差 1,041,409：主列表按
/// `cache_creation_input_tokens` 总数算，明细按 `cache_creation` 的 5m + 1h 拆分算，而上游偶有两者矛盾。
/// 旧测试 `testDetailSurvivesMissingSourceFile` 只手工往账本塞记录再读，从没跑过解析，锁不住这类问题。
final class LedgerConsistencyTests: XCTestCase {

    private func assistantLine(id: String, ts: String, input: Int, output: Int, cacheRead: Int,
                               cacheCreateTotal: Int?, split: (fiveMin: Int, oneHour: Int)?) -> String {
        var usage = "\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheRead)"
        if let t = cacheCreateTotal { usage += ",\"cache_creation_input_tokens\":\(t)" }
        if let s = split {
            usage += ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(s.fiveMin),\"ephemeral_1h_input_tokens\":\(s.oneHour)}"
        }
        return "{\"type\":\"assistant\",\"sessionId\":\"s-1\",\"timestamp\":\"\(ts)\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-opus-4-8\",\"usage\":{\(usage)}}}"
    }

    /// 缓存写入拆分与总数矛盾时：明细以总数为准，主列表由明细汇总，与旧主列表解析器的数逐字相等。
    func testCacheCreationSplitConflictKeepsListAndDetailIdentical() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-consistency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s-1.jsonl")
        let lines = [
            // 拆分与总数一致（新格式常态）
            assistantLine(id: "m1", ts: "2026-08-24T02:00:00.000Z", input: 10, output: 5, cacheRead: 100,
                          cacheCreateTotal: 100, split: (60, 40)),
            // 同一响应流式重复落盘：只计一次
            assistantLine(id: "m1", ts: "2026-08-24T02:00:00.000Z", input: 10, output: 5, cacheRead: 100,
                          cacheCreateTotal: 100, split: (60, 40)),
            // 旧格式：没有拆分对象 → 整块归 5m
            assistantLine(id: "m2", ts: "2026-08-24T02:01:00.000Z", input: 1, output: 1, cacheRead: 0,
                          cacheCreateTotal: 50, split: nil),
            // 真实矛盾 1：总数 0，拆分却有 1h 2,246 → 不能凭空多出缓存写
            assistantLine(id: "m3", ts: "2026-08-24T02:02:00.000Z", input: 3, output: 2, cacheRead: 7,
                          cacheCreateTotal: 0, split: (0, 2_246)),
            // 真实矛盾 2：总数 630,881，拆分只有 1h 2,125 → 1h 取 2,125，其余 628,756 归 5m
            assistantLine(id: "m4", ts: "2026-08-24T02:03:00.000Z", input: 4, output: 6, cacheRead: 9,
                          cacheCreateTotal: 630_881, split: (0, 2_125)),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let details = ClaudeDetailScanner.detailRecords(url: url, providerId: "claude-code", attachSource: false)
        let detailTotal = details.reduce(0) { $0 + $1.tokens.total }
        let fiveMin = details.reduce(0) { $0 + $1.cacheCreate5m }
        let oneHour = details.reduce(0) { $0 + $1.cacheCreate1h }

        // 旧主列表解析器（按总数算）的数 = 本版之前用户在主列表看到的数，必须一个不差。
        let oldList = try ClaudeTranscriptParser.parse(url: url, classify: { _ in "claude-code" }).reduce(0) { $0 + $1.token }
        XCTAssertEqual(oldList, (10 + 5 + 100 + 100) + (1 + 1 + 50) + (3 + 2 + 7) + (4 + 6 + 9 + 630_881))
        XCTAssertEqual(detailTotal, oldList, "明细必须与主列表口径一致")
        XCTAssertEqual(oneHour, 40 + 2_125, "1h 取拆分值且不超过总数；总数为 0 的那条不能多出 2,246")
        XCTAssertEqual(fiveMin, 60 + 50 + 628_756)

        let records = ClaudeDetailScanner.dailyRecords(from: details, provider: "claude-code")
        XCTAssertEqual(records.reduce(0) { $0 + $1.token }, detailTotal, "主列表由明细汇总，按构造相等")
        XCTAssertEqual(records.reduce(0) { $0 + $1.cachedToken }, 100 + 7 + 9)
    }

    /// 命中缓存时的自检：旧版本写下的「主列表 ≠ 明细」记录要被识别出来重算；只看本来源、不受别的来源干扰。
    func testRecordsMatchDetailsDetectsStaleEntries() {
        let d = FileDetailRecord(provider: "claude-code", date: "2026-08-24", sessionId: "s", title: "",
                                 model: "claude-opus-4-8", lastActivity: Date(),
                                 tokens: TokenBreakdown(input: 10, output: 5, cacheCreate5m: 3, cacheCreate1h: 2, cacheRead: 80))
        let good = FileCacheEntry(filePath: "/a", mtime: Date(), size: 1,
                                  records: [FileDailyRecord(provider: "claude-code", date: "2026-08-24", token: 100)],
                                  details: [d])
        let stale = FileCacheEntry(filePath: "/b", mtime: Date(), size: 1,
                                   records: [FileDailyRecord(provider: "claude-code", date: "2026-08-24", token: 726_610)],
                                   details: [d])
        let otherProvider = FileCacheEntry(filePath: "/c", mtime: Date(), size: 1,
                                           records: [FileDailyRecord(provider: "claude-code", date: "2026-08-24", token: 100),
                                                     FileDailyRecord(provider: "cowork", date: "2026-08-24", token: 999)],
                                           details: [d])
        XCTAssertTrue(good.recordsMatchDetails(provider: "claude-code"))
        XCTAssertFalse(stale.recordsMatchDetails(provider: "claude-code"))
        XCTAssertTrue(otherProvider.recordsMatchDetails(provider: "claude-code"))
        XCTAssertTrue(FileCacheEntry(filePath: "/d", mtime: Date(), size: 1, records: []).recordsMatchDetails(provider: "claude-code"),
                      "没有用量的文件两边都是 0")
    }
}
