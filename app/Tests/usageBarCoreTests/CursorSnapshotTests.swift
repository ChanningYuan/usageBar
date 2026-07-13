import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// Cursor 重复计数回归锁（v0.3.22）。
///
/// 根因：Cursor 的用量事件是**累计快照** —— 一条对话进行中会被反复上报，
/// **时间戳固定在对话开始那一刻，token 逐次累加**，服务端只保留终值。
/// 旧去重键是 `时间戳|totalTokens`，token 每次都变 → key 永远不重复 → 去重失效 →
/// 每一份中间快照都被当成新事件累加，实测虚高 **+72%**。
///
/// 同类前科：悟空 `testRolloutCumulativeMustDiffNotSum`、Codex 峰值跟踪。
/// **累计型数据被当成增量累加**是这个项目反复踩的坑，这里把不变量钉死。
final class CursorSnapshotTests: XCTestCase {

    /// 造一行 mirror 记录。四列加总即 total（与实测闭合口径一致）。
    private func row(_ ts: String, _ model: String,
                     prompt: Int, completion: Int, cacheRead: Int, cacheCreate: Int) -> [String: Any] {
        [
            "timestamp": ts,
            "model": model,
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": cacheCreate,
            "total_tokens": prompt + completion + cacheRead + cacheCreate,
            "source": "cursor",
        ]
    }

    /// 核心不变量：同一条对话的多份累计快照，**只取终值，绝不相加**。
    ///
    /// 样本取自 2026-07-13 本机 mirror 的真实数据：同一条对话
    /// （`2026-07-13T08:08:46.812Z` / `claude-fable-5-thinking-high`）存了 4 份快照，
    /// total 依次 `1,891,508 → 5,659,446 → 6,183,595 → 14,504,573`。
    /// 真值 = 终值 14,504,573；旧口径会把 4 份全加 = 28,239,122。
    func testCumulativeSnapshotsMustTakeFinalNotSum() {
        let ts = "2026-07-13T08:08:46.812Z"
        let m = "claude-fable-5-thinking-high"
        // 四列按比例拆，保证 prompt+completion+cacheRead+cacheCreate == 各自的 total
        let objs: [[String: Any]] = [
            row(ts, m, prompt: 1_000, completion: 508, cacheRead: 1_800_000, cacheCreate: 90_000),   // 1,891,508
            row(ts, m, prompt: 3_000, completion: 1_446, cacheRead: 5_500_000, cacheCreate: 155_000), // 5,659,446
            row(ts, m, prompt: 3_500, completion: 2_095, cacheRead: 6_000_000, cacheCreate: 178_000), // 6,183,595
            row(ts, m, prompt: 4_573, completion: 5_000, cacheRead: 14_200_000, cacheCreate: 295_000) // 14,504,573
        ]
        let sumOfAll = objs.reduce(0) { $0 + ($1["total_tokens"] as! Int) }
        let finalValue = objs.map { $0["total_tokens"] as! Int }.max()!
        XCTAssertEqual(sumOfAll, 28_239_122, "样本自检：旧口径（全部相加）应为 28,239,122")
        XCTAssertEqual(finalValue, 14_504_573, "样本自检：终值应为 14,504,573")

        let records = CursorProvider.aggregate(objects: objs, provider: "cursor")
        XCTAssertEqual(records.count, 1)
        let token = records[0].token

        XCTAssertEqual(token, finalValue, "同一 (时间戳,模型) 的多份累计快照必须只取终值")
        XCTAssertNotEqual(token, sumOfAll, "⛔ 回归：中间快照又被累加了（这正是 v0.3.22 修的 bug）")
    }

    /// 不同模型 / 不同时间戳是**不同的 key**，必须各自计入、正常相加 —— 别把修复做成"漏算"。
    func testDistinctKeysStillSum() {
        let objs: [[String: Any]] = [
            row("2026-07-13T08:00:00.000Z", "claude-fable-5", prompt: 100, completion: 10, cacheRead: 0, cacheCreate: 0),
            // 同时间戳、不同模型 → 不同 key
            row("2026-07-13T08:00:00.000Z", "auto", prompt: 200, completion: 20, cacheRead: 0, cacheCreate: 0),
            // 同模型、不同时间戳 → 不同 key
            row("2026-07-13T09:00:00.000Z", "claude-fable-5", prompt: 300, completion: 30, cacheRead: 0, cacheCreate: 0),
        ]
        let records = CursorProvider.aggregate(objects: objs, provider: "cursor")
        XCTAssertEqual(records.count, 1, "同一天应聚合成一条 daily record")
        XCTAssertEqual(records[0].token, 110 + 220 + 330, "不同 key 必须各自计入")
    }

    /// 存量被污染的 mirror **读的时候就自动修正** —— 这是"不需要迁移脚本"的依据。
    /// 快照乱序（终值不在最后）也必须取到最大值。
    func testPollutedMirrorSelfHealsRegardlessOfOrder() {
        let ts = "2026-07-13T07:23:41.679Z"
        let m = "claude-fable-5-thinking-high"
        let objs: [[String: Any]] = [
            row(ts, m, prompt: 100, completion: 37, cacheRead: 2_900_000, cacheCreate: 57_000),  // 2,957,137 ← 终值，放最前
            row(ts, m, prompt: 50, completion: 20, cacheRead: 1_350_000, cacheCreate: 32_569),   // 1,382,639
            row(ts, m, prompt: 80, completion: 25, cacheRead: 2_050_000, cacheCreate: 31_939),   // 2,082,044
        ]
        let records = CursorProvider.aggregate(objects: objs, provider: "cursor")
        XCTAssertEqual(records[0].token, 2_957_137, "乱序时也必须取最大（终值），而非最后一条")
    }

    /// 去重键必须是「时间戳 + 模型」，且序列化/反序列化两侧同构 —— 不同构会让去重再次失效。
    func testDedupeKeyIsTimestampPlusModelAndRoundTrips() {
        let ev = CursorUsageEvent(
            timestampISO: "2026-07-13T08:08:46.812Z", model: "claude-fable-5-thinking-high",
            inputNoCache: 4_573, inputWithCache: 295_000, cacheRead: 14_200_000,
            output: 5_000, totalTokens: 14_504_573, cost: "-")

        XCTAssertEqual(ev.dedupeKey, "2026-07-13T08:08:46.812Z|claude-fable-5-thinking-high")
        XCTAssertFalse(ev.dedupeKey.contains("14504573"), "⛔ 回归：key 里又混进 token 了 → 去重必然失效")

        let line = ev.toJSONLine()
        XCTAssertEqual(CursorUsageEvent.dedupeKey(fromJSONLine: line), ev.dedupeKey,
                       "写入侧与读取侧的 key 必须同构")
        XCTAssertEqual(CursorUsageEvent.totalTokens(fromJSONLine: line), 14_504_573)
    }
}
