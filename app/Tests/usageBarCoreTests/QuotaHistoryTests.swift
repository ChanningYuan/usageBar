import XCTest
@testable import usageBarCore

/// 信用点额度历史流水（v0.3.26）回归锁。
///
/// 语义（0716 定稿）：按 (provider, pool) 只在 **used / total 变化**时追加一行；
/// `plan` / `resetsAt` 随行携带但**不触发**；跨 app 重启靠通读存量文件恢复"上一条"，不重复记。
final class QuotaHistoryTests: XCTestCase {

    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageBar-qh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("quota-history.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func lines() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map {
            try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    private func snap(used: Double, total: Double, pool: String = "monthly",
                      plan: String? = "teams", resetsAt: Date? = nil,
                      error: RateLimitError? = nil) -> RateLimitSnapshot {
        let w = RateLimitWindow(kind: pool, label: "月", usedPercent: used / total * 100,
                                resetsAt: resetsAt, detail: nil, used: used, total: total)
        return RateLimitSnapshot(providerId: "qoder-work", windows: [w],
                                 planType: plan, capturedAt: Date(), error: error)
    }

    func testAppendsOnChangeSkipsWhenUnchanged() async throws {
        let store = QuotaHistoryStore(fileURL: file)
        await store.record(provider: "qoder", snapshot: snap(used: 100, total: 5000))
        await store.record(provider: "qoder", snapshot: snap(used: 100, total: 5000))   // 没变 → 跳过
        await store.record(provider: "qoder", snapshot: snap(used: 130, total: 5000))   // used 变 → 记

        let rows = try lines()
        XCTAssertEqual(rows.count, 2, "⛔ 应为：首条 + used 变化各一行，纹丝不动那次不记")
        XCTAssertEqual(rows[0]["used"] as? Double, 100)
        XCTAssertEqual(rows[1]["used"] as? Double, 130)
        XCTAssertEqual(rows[0]["provider"] as? String, "qoder")
        XCTAssertEqual(rows[0]["pool"] as? String, "monthly")
    }

    func testResetsAtAloneDoesNotTrigger() async throws {
        let store = QuotaHistoryStore(fileURL: file)
        await store.record(provider: "qoder",
                           snapshot: snap(used: 100, total: 5000, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)))
        await store.record(provider: "qoder",
                           snapshot: snap(used: 100, total: 5000, resetsAt: Date(timeIntervalSince1970: 1_900_000_000)))
        let rows = try lines()
        XCTAssertEqual(rows.count, 1, "⛔ resetsAt 是随行字段，单独变化不该触发写入（0716 定稿）")
    }

    func testSurvivesRestartWithoutDuplicating() async throws {
        await QuotaHistoryStore(fileURL: file).record(provider: "workbuddy",
                                                      snapshot: snap(used: 230.5, total: 6000, plan: "标准资源包"))
        // 模拟 app 重启：新实例、同一文件。相同数值 → 不重复；变化 → 记。
        let reborn = QuotaHistoryStore(fileURL: file)
        await reborn.record(provider: "workbuddy", snapshot: snap(used: 230.5, total: 6000, plan: "标准资源包"))
        await reborn.record(provider: "workbuddy", snapshot: snap(used: 231.5, total: 6000, plan: "标准资源包"))

        let rows = try lines()
        XCTAssertEqual(rows.count, 2, "⛔ 重启后没从存量文件恢复\"上一条\"，重复记了")
        XCTAssertEqual(rows[1]["used"] as? Double, 231.5)
    }

    func testTeamsTwoPoolsTrackedIndependently() async throws {
        let store = QuotaHistoryStore(fileURL: file)
        let seat = RateLimitWindow(kind: "monthly", label: "套餐", usedPercent: 2,
                                   detail: nil, used: 100, total: 5000)
        let pack = RateLimitWindow(kind: "pack", label: "资源包", usedPercent: 1.2,
                                   detail: nil, used: 120, total: 10000)
        let both = RateLimitSnapshot(providerId: "qoder-work", windows: [seat, pack],
                                     planType: "teams", capturedAt: Date(), error: nil)
        await store.record(provider: "qoder", snapshot: both)

        // 只有资源包动了 → 只追加 pack 一行
        let pack2 = RateLimitWindow(kind: "pack", label: "资源包", usedPercent: 1.5,
                                    detail: nil, used: 150, total: 10000)
        let second = RateLimitSnapshot(providerId: "qoder-work", windows: [seat, pack2],
                                       planType: "teams", capturedAt: Date(), error: nil)
        await store.record(provider: "qoder", snapshot: second)

        let rows = try lines()
        XCTAssertEqual(rows.count, 3, "⛔ 双池应独立判变：首轮 2 行 + 第二轮只有 pack 1 行")
        XCTAssertEqual(rows[2]["pool"] as? String, "pack")
        XCTAssertEqual(rows[2]["used"] as? Double, 150)
    }

    func testErrorSnapshotNotRecorded() async throws {
        let store = QuotaHistoryStore(fileURL: file)
        await store.record(provider: "qoder", snapshot: snap(used: 100, total: 5000, error: .network))
        let rows = try lines()
        XCTAssertTrue(rows.isEmpty, "⛔ 失败快照的 windows 可能陈旧，不该进历史")
    }

    /// 百分比型窗口（Claude/Codex/Cursor 无原始点数）也记：按 usedPercent 判变（1b 定稿，0717）。
    func testPercentWindowRecordedAndTriggersOnPercentChange() async throws {
        let store = QuotaHistoryStore(fileURL: file)
        func s(_ pct: Double) -> RateLimitSnapshot {
            let w = RateLimitWindow(kind: "five_hour", label: "5h", usedPercent: pct)
            return RateLimitSnapshot(providerId: "claude-code", windows: [w],
                                     planType: "max", capturedAt: Date(), error: nil)
        }
        await store.record(provider: "claude-code", snapshot: s(37))
        await store.record(provider: "claude-code", snapshot: s(37))   // 没变 → 跳过
        await store.record(provider: "claude-code", snapshot: s(41))

        let rows = try lines()
        XCTAssertEqual(rows.count, 2, "⛔ 百分比池应记录且只在 usedPercent 变化时追加")
        XCTAssertEqual(rows[1]["usedPercent"] as? Double, 41)
        XCTAssertNil(rows[0]["used"], "百分比池的行不该有 used/total 字段")
    }

    /// Claude 分模型窗口（scopeModel）与总窗口是不同的池，必须独立判变、行里带 model 字段。
    func testScopedModelWindowTrackedSeparately() async throws {
        let store = QuotaHistoryStore(fileURL: file)
        func s(all: Double, opus: Double) -> RateLimitSnapshot {
            let w1 = RateLimitWindow(kind: "seven_day", label: "7d", usedPercent: all)
            let w2 = RateLimitWindow(kind: "seven_day_opus", label: "Opus", usedPercent: opus,
                                     scopeModel: "Opus")
            return RateLimitSnapshot(providerId: "claude-code", windows: [w1, w2],
                                     planType: "max", capturedAt: Date(), error: nil)
        }
        await store.record(provider: "claude-code", snapshot: s(all: 10, opus: 5))
        await store.record(provider: "claude-code", snapshot: s(all: 10, opus: 8))  // 只有 Opus 动了

        let rows = try lines()
        XCTAssertEqual(rows.count, 3, "⛔ 首轮 2 行 + 第二轮只有 Opus 池 1 行")
        XCTAssertEqual(rows[2]["model"] as? String, "Opus")
        XCTAssertEqual(rows[2]["usedPercent"] as? Double, 8)
    }
}
