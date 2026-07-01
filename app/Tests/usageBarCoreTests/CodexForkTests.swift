import XCTest
import usageBarCore
@testable import usageBarProviders

/// CodexProvider fork/resume 跨文件去重的单测（交接文档 §4.2 / §4.4）。
final class CodexForkTests: XCTestCase {

    /// §4.4 真实 fork 序列对拍：fork 文件 replay 父到 160320，新增到 201425 → 去重后只算 41105。
    func testRealForkDiffSum() {
        let forkSeq = [40055, 40055, 80129, 80129, 120216, 120216, 160320, 160320, 201425]
        XCTAssertEqual(CodexProvider.diffSum(totals: forkSeq, baseline: 160320), 41105)
    }

    /// 非 fork（baseline=0）必须等于旧算法（单调序列 → final）。锁不变量3。
    func testNonForkEqualsOldAlgorithm() {
        let seq = [22916, 100000, 300000, 666116]
        XCTAssertEqual(CodexProvider.diffSum(totals: seq, baseline: 0), 666116)
    }

    /// §4.2 多 fork 合成：父 160000 + 三 fork(200000/210000/240000) → 330000（不是 buggy 的 810000）。
    func testSyntheticMultiFork() {
        let replay = [40000, 80000, 120000, 160000]
        let parent = CodexProvider.diffSum(totals: replay, baseline: 0)
        let f1 = CodexProvider.diffSum(totals: replay + [200000], baseline: 160000)
        let f2 = CodexProvider.diffSum(totals: replay + [210000], baseline: 160000)
        let f3 = CodexProvider.diffSum(totals: replay + [240000], baseline: 160000)
        XCTAssertEqual(parent, 160000)
        XCTAssertEqual(parent + f1 + f2 + f3, 330000)

        // 对照：修复前（每文件都 baseline=0）会把父历史重算 → 810000
        let buggy = [replay, replay + [200000], replay + [210000], replay + [240000]]
            .map { CodexProvider.diffSum(totals: $0, baseline: 0) }
            .reduce(0, +)
        XCTAssertEqual(buggy, 810000)
    }

    /// 峰值跟踪（改②）：replay 段中途跌回小值再爬回父 final，不被重算。
    /// 只改①不改②会得 > 41105（HTML Tab D 警告）。
    func testPeakTrackingPreventsRecount() {
        let seq = [50000, 100000, 160320, 100000, 160320, 201425]  // 中途跌回 100000
        XCTAssertEqual(CodexProvider.diffSum(totals: seq, baseline: 160320), 41105)
    }

    /// 父缺失（fork 引用的父不在）→ baseline=0 自愈，按全量算（不重不漏）。
    func testMissingParentFallsBackToFull() {
        let forkSeq = [40055, 80129, 160320, 201425]
        XCTAssertEqual(CodexProvider.diffSum(totals: forkSeq, baseline: 0), 201425)
    }

    /// computeDaily：跨天拆分 + 峰值跟踪，daily 之和 == fileFinal。
    func testComputeDailySplitsByDayAndSumsToFinal() {
        let tsA = ISODateParser.parse("2026-05-11T01:00:00.000Z")!
        let tsB = ISODateParser.parse("2026-05-12T01:00:00.000Z")!  // 约 +24h，本地日界跨天
        // (ts, total, cached)
        let (daily, cachedDaily, fileFinal, cachedFinal) = CodexProvider.computeDaily(
            events: [(tsA, 100, 30), (tsB, 350, 80)], baseline: 0, cachedBaseline: 0)
        XCTAssertEqual(fileFinal, 350)
        XCTAssertEqual(cachedFinal, 80)
        XCTAssertEqual(daily.values.reduce(0, +), 350)
        XCTAssertEqual(cachedDaily.values.reduce(0, +), 80)  // 30 + 50
        XCTAssertEqual(daily.count, 2, "跨两个本地日应拆成两桶")
    }

    /// cached 逐 event 增量可能 > total 增量 → 必须 clamp，保证 cachedToken ≤ token（浅色不超总长）。
    func testCodexCachedClampedToTotal() {
        let tsA = ISODateParser.parse("2026-05-11T01:00:00.000Z")!
        let tsB = ISODateParser.parse("2026-05-11T02:00:00.000Z")!  // 同一本地日
        // 第二步 total 只 +10，cached 却 +50 → clamp 到 10
        let (daily, cachedDaily, _, _) = CodexProvider.computeDaily(
            events: [(tsA, 100, 20), (tsB, 110, 70)], baseline: 0, cachedBaseline: 0)
        let day = daily.keys.first!
        XCTAssertEqual(daily[day], 110)                          // 100 + 10
        XCTAssertEqual(cachedDaily[day], 30)                     // 20 + min(50,10)=10（未 clamp 会是 70）
        XCTAssertLessThanOrEqual(cachedDaily[day]!, daily[day]!) // 浅色 ≤ total
    }
}
