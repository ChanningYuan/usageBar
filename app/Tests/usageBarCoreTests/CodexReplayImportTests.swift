import XCTest
import usageBarCore
@testable import usageBarProviders

/// Codex Desktop「从其他 AI 应用导入」生成的 replay 快照不计量（GitHub issue：列表 4.3M vs 详情 1.8M）。
/// 快照特征（本机复现：41 文件同一秒落盘）：单条 token_count、total_tokens>0 而
/// input/cached/output/reasoning 全 0。口径修复 = eventTotal 用 input+output（与详情页统一）。
final class CodexReplayImportTests: XCTestCase {

    /// 真实事件：细分键存在 → input+output。数字取自 issue 的详情页复算值，恒等于 total_tokens。
    func testEventTotalUsesBreakdownWhenPresent() {
        let usage: [String: Any] = [
            "total_tokens": 1_801_614,
            "input_tokens": 1_772_782,
            "cached_input_tokens": 1_590_528,
            "output_tokens": 28_832,
            "reasoning_output_tokens": 12_000,
        ]
        XCTAssertEqual(CodexProvider.eventTotal(usage), 1_801_614)
    }

    /// replay 快照：total>0 且细分全 0 → 归零，不再把导入的历史会话算进导入当天。
    func testReplaySnapshotCountsZero() {
        let usage: [String: Any] = [
            "total_tokens": 2_476_509,
            "input_tokens": 0,
            "cached_input_tokens": 0,
            "output_tokens": 0,
            "reasoning_output_tokens": 0,
        ]
        XCTAssertEqual(CodexProvider.eventTotal(usage), 0)
    }

    /// 细分键完全缺失（未知旧格式）→ 回退 total_tokens，不丢真实用量。
    func testFallbackToTotalWhenBreakdownAbsent() {
        XCTAssertEqual(CodexProvider.eventTotal(["total_tokens": 12_345]), 12_345)
    }

    /// 端到端形状：replay-only 文件经 eventTotal 归零后，computeDaily 不产生任何日期桶。
    func testReplayOnlyFileProducesNoDailyRecords() {
        let ts = ISODateParser.parse("2026-07-10T15:50:44.000Z")!
        let (daily, cachedDaily, fileFinal, cachedFinal) = CodexProvider.computeDaily(
            events: [(ts, 0, 0)], baseline: 0, cachedBaseline: 0)
        XCTAssertTrue(daily.isEmpty)
        XCTAssertTrue(cachedDaily.isEmpty)
        XCTAssertEqual(fileFinal, 0)
        XCTAssertEqual(cachedFinal, 0)
    }

    /// 导入会话被用户继续使用：replay 事件(0)后跟真实事件，真实增量从 0 起全额计入、不受污染。
    func testResumedImportedSessionCountsOnlyRealUsage() {
        let t1 = ISODateParser.parse("2026-07-10T15:50:44.000Z")!
        let t2 = ISODateParser.parse("2026-07-10T16:00:00.000Z")!
        let t3 = ISODateParser.parse("2026-07-10T16:10:00.000Z")!
        let (daily, _, fileFinal, _) = CodexProvider.computeDaily(
            events: [(t1, 0, 0), (t2, 100, 20), (t3, 250, 60)], baseline: 0, cachedBaseline: 0)
        XCTAssertEqual(daily.values.reduce(0, +), 250)
        XCTAssertEqual(fileFinal, 250)
    }
}
