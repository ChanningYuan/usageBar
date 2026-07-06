import XCTest
import usageBarCore
@testable import usageBarProviders

/// 悟空 `cacheTokens` → `cachedToken` 解析回归测试（v0.3.11 修复）。
///
/// 背景：v0.3.10 未解析悟空缓存字段 → 命中率恒 0%。v0.3.11 加解析后仍报空，
/// 排查发现是发布二进制漏编 + 需 clean 重建。此测试锁死解析逻辑，防：
///   - 字段名回退（源 jsonl 是复数 `cacheTokens`，模型是单数 `cachedToken`，别写反）
///   - 老记录（2026-05-18 前无该字段）未 `?? 0` 兜底
final class WukongProviderTests: XCTestCase {

    func testCacheTokensMapsToCachedToken() throws {
        // 同事机真实样例值 + 一条 2026-05-18 前的老记录（整个 cacheTokens key 缺失）
        let lines = [
            #"{"createdAtMs":1782808365166,"promptTokens":35021,"completionTokens":91,"totalTokens":35112,"cacheTokens":34544,"provider":"dingtalk_deap"}"#,
            #"{"createdAtMs":1782808300000,"promptTokens":27770,"completionTokens":50,"cacheTokens":28244}"#,
            #"{"createdAtMs":1782808200000,"promptTokens":100,"completionTokens":50}"#,  // 老记录无 cacheTokens → cached 记 0
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("requests.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let records = try WukongProvider().parseFile(url: url)
        let total = records.reduce(0) { $0 + $1.token }
        let cached = records.reduce(0) { $0 + $1.cachedToken }

        XCTAssertEqual(total, 35112 + 27820 + 150, "total = prompt + completion（不含 cache 重复计）")
        XCTAssertEqual(cached, 34544 + 28244, "cachedToken 只累加有 cacheTokens 的行；老记录按 0")
        XCTAssertGreaterThan(cached, 0, "cachedToken 必须 > 0，否则 UI 命中率整行不显示")
    }

    // MARK: - 源 B · codex rollout（v0.3.14，0.9.66 新落点）

    /// 锁死核心不变量：`total_token_usage.total_tokens` 是**累计值**，必须差分。
    /// 用同事机实测的累计序列（单调递增），断言差分总量 == 最后一条累计值，
    /// 且**远小于**朴素求和（后者=把累计值重复叠加的错误结果）。
    func testRolloutCumulativeMustDiffNotSum() throws {
        // 同事机 2026-07-06 实测 total_token_usage.total_tokens 累计序列
        let totals = [19715, 39448, 61080, 82933, 106917]
        var lines = [
            #"{"type":"session_meta","payload":{"id":"s1","source":"vscode"}}"#,
            #"{"type":"turn_context","payload":{}}"#,   // 非 token_count → 应忽略
        ]
        for (i, t) in totals.enumerated() {
            let ts = "2026-07-06T11:0\(i):00.000Z"
            lines.append(
                #"{"timestamp":"\#(ts)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(t),"cached_input_tokens":0}}}}"#
            )
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-2026-07-06T11-00-00-abc.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let events = WukongProvider().parseRolloutEvents(url: url)
        XCTAssertEqual(events.count, 5, "只收 5 条 token_count，session_meta/turn_context 被忽略")

        let (daily, _, _, _) = CodexProvider.computeDaily(events: events, baseline: 0, cachedBaseline: 0)
        let sum = daily.values.reduce(0, +)
        XCTAssertEqual(sum, 106917, "差分总量 == 最后一条累计值（telescope 到 last-baseline）")
        XCTAssertNotEqual(sum, totals.reduce(0, +), "绝不能等于朴素求和 310093（那是把累计值重复叠加的虚高）")
    }

    /// cached_input_tokens 逐 event 增量 clamp 到 total 增量 → cachedToken ≤ token（浅色段不超总长）。
    func testRolloutCachedClampedToToken() throws {
        let lines = [
            #"{"timestamp":"2026-07-06T11:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10000,"cached_input_tokens":9000}}}}"#,
            #"{"timestamp":"2026-07-06T11:01:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10500,"cached_input_tokens":10200}}}}"#,
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-2026-07-06T11-00-00-def.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let events = WukongProvider().parseRolloutEvents(url: url)
        let (daily, cachedDaily, _, _) = CodexProvider.computeDaily(events: events, baseline: 0, cachedBaseline: 0)
        for (date, token) in daily {
            XCTAssertLessThanOrEqual(cachedDaily[date] ?? 0, token, "cachedToken 必须 ≤ token")
        }
    }

    /// 全部无 cacheTokens（模拟 2026-05-18 前的纯老数据）→ cachedToken 恒 0、不崩、total 正常。
    func testLegacyRecordsWithoutCacheField() throws {
        let lines = [
            #"{"createdAtMs":1778751185569,"promptTokens":25757,"completionTokens":100}"#,
            #"{"createdAtMs":1778751200000,"promptTokens":300,"completionTokens":50}"#,
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("requests.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let records = try WukongProvider().parseFile(url: url)
        let cached = records.reduce(0) { $0 + $1.cachedToken }
        let total = records.reduce(0) { $0 + $1.token }
        XCTAssertEqual(cached, 0)
        XCTAssertEqual(total, 25857 + 350)
    }
}
