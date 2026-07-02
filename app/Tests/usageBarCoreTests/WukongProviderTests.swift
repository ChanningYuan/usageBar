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
