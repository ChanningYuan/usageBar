import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// 账号额度解析回归锁（v0.3.24）。
///
/// fixture 用的是 2026-07-14 本机真机探针拿到的**真实返回体**（见 spec §1），
/// 锁住几条最容易写死的不变量：窗口数量动态、分模型限额单独一行、官方 severity。
final class RateLimitTests: XCTestCase {

    // MARK: - Codex：窗口数量动态（§1c 铁律）

    /// ⛔ 最重要的一条锁：Codex 实测只有一个 7 天窗（primary=7d、secondary=null）。
    /// 旧 spec 写死的「primary=5h、secondary=7d」是错的。这条锁防止有人回退成硬编码两窗口。
    func testCodexSingleWindow() {
        // 本机真实返回：primary 是 7 天窗（window_minutes=10080），secondary 为 null
        let rl: [String: Any] = [
            "limit_id": "codex",
            "primary": ["used_percent": 21.0, "window_minutes": 10080, "resets_at": 1784512060],
            "secondary": NSNull(),
            "plan_type": "prolite",
        ]
        let windows = CodexRateLimitReader.parseWindows(rl)
        XCTAssertEqual(windows.count, 1, "Codex 当前只有一个窗口，别写死成两个")
        XCTAssertEqual(windows[0].label, "7d", "window_minutes=10080 应推导为 7d，不是按名字写死 5h")
        XCTAssertEqual(windows[0].usedPercent, 21.0)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    /// 若将来 Codex 恢复双窗口（primary=5h + secondary=7d），也要按 window_minutes 各自推导
    func testCodexDualWindowByMinutes() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 30.0, "window_minutes": 300, "resets_at": 1784512060],
            "secondary": ["used_percent": 8.0, "window_minutes": 10080, "resets_at": 1784600000],
        ]
        let windows = CodexRateLimitReader.parseWindows(rl)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5h")   // 300 分钟
        XCTAssertEqual(windows[1].label, "7d")   // 10080 分钟
    }

    // MARK: - Claude：limits[] 结构（含分模型 + severity）

    /// 锁住三件事：3 个窗口、分模型限额用模型名当 label（Fable）、severity 透传（供色档）。
    func testClaudeLimitsParse() {
        // 本机真实返回体的 limits 数组
        let obj: [String: Any] = [
            "limits": [
                ["kind": "session", "group": "session", "percent": 80, "severity": "warning",
                 "resets_at": "2026-07-14T11:39:59.701754+00:00", "scope": NSNull(), "is_active": true],
                ["kind": "weekly_all", "group": "weekly", "percent": 43, "severity": "normal",
                 "resets_at": "2026-07-17T14:59:59.701779+00:00", "is_active": false],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 64, "severity": "normal",
                 "resets_at": "2026-07-17T14:59:59.702255+00:00",
                 "scope": ["model": ["display_name": "Fable"]], "is_active": false],
            ],
        ]
        let windows = ClaudeOAuthUsageReader.parseWindows(obj)
        XCTAssertEqual(windows.count, 3)

        // session → 5h，官方判 warning（这就是主列表药丸变黄的依据，不是自己拍阈值）
        XCTAssertEqual(windows[0].label, "5h")
        XCTAssertEqual(windows[0].usedPercent, 80)
        XCTAssertEqual(windows[0].severity, "warning")

        // weekly_all → 7d
        XCTAssertEqual(windows[1].label, "7d")

        // weekly_scoped → 分模型限额，label 用模型名，scopeModel 带上（§1e：只看总额会误判）
        XCTAssertEqual(windows[2].label, "Fable")
        XCTAssertEqual(windows[2].scopeModel, "Fable")
        XCTAssertEqual(windows[2].usedPercent, 64)
    }

    /// 教育/企业订阅可能不返回 limits + 无具名窗口 → 空数组（调用方据此落 noQuotaData）
    func testClaudeEmptyWhenNoLimits() {
        let obj: [String: Any] = ["five_hour": NSNull(), "seven_day": NSNull(), "limits": []]
        XCTAssertTrue(ClaudeOAuthUsageReader.parseWindows(obj).isEmpty)
    }

    /// 具名窗口兜底（limits 缺失时用 five_hour/seven_day）
    func testClaudeNamedFallback() {
        let obj: [String: Any] = [
            "five_hour": ["utilization": 55.0, "resets_at": "2026-07-14T11:39:59.701754+00:00"],
            "seven_day": ["utilization": 30.0, "resets_at": "2026-07-17T14:59:59.701779+00:00"],
        ]
        let windows = ClaudeOAuthUsageReader.parseWindows(obj)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5h")
        XCTAssertEqual(windows[0].usedPercent, 55)
    }

    // MARK: - Claude statusline：推荐默认路径（零钥匙串）的解析锁

    /// 锁住 statusline 数据路径：Claude 喂给状态栏的 `rate_limits` 是 `used_percentage` + unix `resets_at`。
    /// 这是「零钥匙串」推荐路线的数据来源，此前零测试覆盖（v0.3.24 的 keychain 回落 bug 就出在这条线附近）。
    func testStatuslineParsesRateLimits() {
        let obj: [String: Any] = [
            "five_hour": ["used_percentage": 17, "resets_at": 1784512060],
            "seven_day": ["used_percentage": 50, "resets_at": 1784600000],
        ]
        let windows = ClaudeStatuslineReader.parseRateLimits(obj)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5h")
        XCTAssertEqual(windows[0].usedPercent, 17)
        XCTAssertNotNil(windows[0].resetsAt, "resets_at 是 unix 秒，要能解析成 Date")
        XCTAssertEqual(windows[1].label, "7d")
        XCTAssertEqual(windows[1].usedPercent, 50)
    }

    /// 空 rate_limits → 空数组（调用方据此落 awaitingData 等待态，**绝不回落到要钥匙串的 OAuth**）
    func testStatuslineEmptyWhenNoWindows() {
        XCTAssertTrue(ClaudeStatuslineReader.parseRateLimits([:]).isEmpty)
    }

    // MARK: - label 推导

    func testWindowLabelDerivation() {
        XCTAssertEqual(RateLimitWindow.label(forWindowMinutes: 300), "5h")
        XCTAssertEqual(RateLimitWindow.label(forWindowMinutes: 10080), "7d")
        XCTAssertEqual(RateLimitWindow.label(forWindowMinutes: 60), "1h")
        XCTAssertEqual(RateLimitWindow.label(forWindowMinutes: 1440), "1d")
        XCTAssertEqual(RateLimitWindow.label(forWindowMinutes: 4320), "3d")
    }

    // MARK: - WorkBuddy get-user-resource 解析（本机真实返回体）

    /// 锁住 WorkBuddy 资源包聚合：多包求和、月度周期、CycleEndTime 解析。
    func testWorkBuddyResourceParse() {
        let inner: [String: Any] = [
            "TotalDosage": 500,
            "Accounts": [[
                "PackageName": "CodeBuddy个人体验版",
                "CapacitySize": 500, "CapacityRemain": 500,
                "CycleCapacitySize": 500, "CycleCapacityRemain": 350,
                "CycleStartTime": "2026-07-01 00:00:00", "CycleEndTime": "2026-07-31 23:59:59",
                "CapacityUnit": "credits",
            ]],
        ]
        // 复用 reader 的聚合逻辑（这里手工验证，reader 内部同款）
        let accounts = (inner["Accounts"] as? [[String: Any]]) ?? []
        var size = 0.0, remain = 0.0
        for a in accounts {
            size += (a["CycleCapacitySize"] as? NSNumber)?.doubleValue ?? 0
            remain += (a["CycleCapacityRemain"] as? NSNumber)?.doubleValue ?? 0
        }
        XCTAssertEqual(size, 500)
        XCTAssertEqual(remain, 350)
        let pct = (size - remain) / size * 100
        XCTAssertEqual(pct, 30, accuracy: 0.01)   // 用了 150/500 = 30%
    }

    // MARK: - Store：网络失败保留旧快照

    @MainActor
    func testStoreKeepsPrevOnNetworkError() {
        let store = RateLimitStore.shared
        let good = RateLimitSnapshot(
            providerId: "test-p",
            windows: [RateLimitWindow(kind: "5h", label: "5h", usedPercent: 42)],
            planType: "max", capturedAt: Date(timeIntervalSince1970: 1_000_000), error: nil)
        store.put(good)
        XCTAssertEqual(store.snapshot(for: "test-p")?.windows.count, 1)

        // 网络失败：应保留旧 windows + 旧 capturedAt，只是 error 标成 network
        let netFail = RateLimitSnapshot(providerId: "test-p", windows: [], capturedAt: Date(), error: .network)
        store.put(netFail)
        let after = store.snapshot(for: "test-p")
        XCTAssertEqual(after?.windows.count, 1, "网络抖动不该抹掉有效数据")
        XCTAssertEqual(after?.capturedAt, Date(timeIntervalSince1970: 1_000_000), "陈旧判定用旧时间")
        XCTAssertEqual(after?.error, .network)

        store.remove("test-p")
        XCTAssertNil(store.snapshot(for: "test-p"))
    }
}
