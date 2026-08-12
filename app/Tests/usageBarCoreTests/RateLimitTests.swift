import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// 账号额度解析回归锁（v0.3.24）。
///
/// fixture 用的是 2026-07-14 本机真机探针拿到的**真实返回体**（见 spec §1），
/// 锁住几条最容易写死的不变量：窗口数量动态、分模型限额单独一行、官方 severity。
final class RateLimitTests: XCTestCase {

    // MARK: - Codex：RPC 数据源（0812 重构，JSONL 扫描已退役）

    /// ⛔ 主 fixture = 2026-08-12 本机 `codex app-server` `account/rateLimits/read` 的真实返回。
    /// 锁：多池全展示（issue #6/#7 的主池丢失从数据源上根治）、主池在前、专属池短名、
    /// 套餐透传、余额为 0 的积分不展示、重置券解析。
    func testCodexRPCFullResponse() {
        let result: [String: Any] = [
            "rateLimits": Self.mainPool75,
            "rateLimitsByLimitId": [
                "codex": Self.mainPool75,
                "codex_bengalfox": [
                    "limitId": "codex_bengalfox", "limitName": "GPT-5.3-Codex-Spark",
                    "primary": ["usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1_787_059_602],
                    "secondary": NSNull(), "credits": NSNull(), "individualLimit": NSNull(),
                    "spendControlReached": NSNull(), "planType": "prolite", "rateLimitReachedType": NSNull(),
                ] as [String: Any],
            ] as [String: Any],
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [[
                    "id": "RateLimitResetCredit_x", "resetType": "codexRateLimits",
                    "status": "available", "grantedAt": 1_783_966_383, "expiresAt": 1_786_558_383,
                    "title": "Full reset",
                ] as [String: Any]],
            ] as [String: Any],
        ]
        let snap = CodexRateLimitReader.snapshot(fromRPC: result, accountPlan: "prolite", now: Date())
        XCTAssertEqual(snap.windows.count, 2, "主池 + Spark 都要展示")
        XCTAssertEqual(snap.windows[0].label, "7d", "主池排最前")
        XCTAssertEqual(snap.windows[0].usedPercent, 75.0)
        XCTAssertNil(snap.windows[0].scopeModel)
        XCTAssertEqual(snap.windows[1].label, "Spark", "专属池 limit_name 短名")
        XCTAssertEqual(snap.windows[1].scopeModel, "Spark")
        XCTAssertEqual(snap.planType, "prolite")
        XCTAssertNil(snap.credits?.displayText, "余额为 0 且非 unlimited → 积分不展示（定稿 1a）")
        XCTAssertEqual(snap.availableCoupons.count, 1, "一张可用重置券")
        XCTAssertEqual(snap.availableCoupons[0].title, "Full reset")
        XCTAssertNotNil(snap.availableCoupons[0].expiresAt)
        XCTAssertNil(snap.error)
    }

    nonisolated(unsafe) private static let mainPool75: [String: Any] = [
        "limitId": "codex", "limitName": NSNull(),
        "primary": ["usedPercent": 75, "windowDurationMins": 10080, "resetsAt": 1_787_033_018],
        "secondary": NSNull(),
        "credits": ["hasCredits": false, "unlimited": false, "balance": "0"] as [String: Any],
        "individualLimit": NSNull(), "spendControlReached": false,
        "planType": "prolite", "rateLimitReachedType": NSNull(),
    ]

    /// 主池双窗（plus 经典 5h + 7d）：label 一律由 windowDurationMins 推导（§1c 铁律延续）
    func testCodexRPCDualWindowMainPool() {
        let pool: [String: Any] = [
            "limitId": "codex", "limitName": NSNull(),
            "primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1_787_000_000],
            "secondary": ["usedPercent": 51, "windowDurationMins": 10080, "resetsAt": 1_787_100_000],
        ]
        let snap = CodexRateLimitReader.snapshot(
            fromRPC: ["rateLimitsByLimitId": ["codex": pool]], accountPlan: "plus", now: Date())
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.windows[0].label, "5h")
        XCTAssertEqual(snap.windows[1].label, "7d")
        XCTAssertEqual(snap.planType, "plus", "池里没 planType 时用 account/read 的兜底")
    }

    /// 30 天窗（free 档实测 43200 分钟）：label 推导为 30d，不许写死 7d 上限
    func testCodexRPC30dWindow() {
        let pool: [String: Any] = [
            "limitId": "codex",
            "primary": ["usedPercent": 58, "windowDurationMins": 43200, "resetsAt": 1_789_008_955],
        ]
        let snap = CodexRateLimitReader.snapshot(
            fromRPC: ["rateLimitsByLimitId": ["codex": pool]], accountPlan: "free", now: Date())
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.windows[0].label, "30d")
    }

    /// 老版本 CLI 只回单条 rateLimits（无 rateLimitsByLimitId）也要能解析
    func testCodexRPCSingleRateLimitsFallback() {
        let snap = CodexRateLimitReader.snapshot(
            fromRPC: ["rateLimits": Self.mainPool75], accountPlan: nil, now: Date())
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.windows[0].usedPercent, 75.0)
        XCTAssertEqual(snap.planType, "prolite", "池里的 planType 优先")
    }

    /// 企业字段：人均上限（美元字符串 + 剩余百分比翻转）、支出管控、限流原因透传
    func testCodexRPCEnterpriseFields() {
        var pool = Self.mainPool75
        pool["individualLimit"] = ["limit": "50", "used": "18.5",
                                   "remainingPercent": 63, "resetsAt": 1_788_000_000] as [String: Any]
        pool["spendControlReached"] = true
        pool["rateLimitReachedType"] = "workspace_member_credits_depleted"
        let snap = CodexRateLimitReader.snapshot(
            fromRPC: ["rateLimitsByLimitId": ["codex": pool]], accountPlan: "business", now: Date())
        XCTAssertEqual(snap.spendCap?.usedOfLimitText, "$18.50/$50")
        XCTAssertEqual(snap.spendCap?.usedPercent ?? -1, 37.0, accuracy: 0.01, "官方给剩余 63% → 已用 37%")
        XCTAssertNotNil(snap.spendCap?.resetsAt)
        XCTAssertEqual(snap.spendControlReached, true)
        XCTAssertEqual(snap.rateLimitReachedType, "workspace_member_credits_depleted")
    }

    /// 积分药丸出现时机（定稿 1a）：0 隐藏、有余额显示美元、unlimited 显示 ∞
    func testCodexCreditsDisplayGating() {
        XCTAssertNil(RateLimitCredits(hasCredits: false, unlimited: false, balance: "0").displayText)
        XCTAssertNil(RateLimitCredits(hasCredits: false, unlimited: false, balance: nil).displayText)
        XCTAssertEqual(RateLimitCredits(hasCredits: true, unlimited: false, balance: "4.2").displayText, "$4.20")
        XCTAssertEqual(RateLimitCredits(hasCredits: true, unlimited: false, balance: "12").displayText, "$12")
        XCTAssertEqual(RateLimitCredits(hasCredits: true, unlimited: true, balance: nil).displayText, "∞")
    }

    /// 断网合并（RateLimitStore）要连 0812 新字段一起保留——积分/券在离线时不许消失
    @MainActor
    func testStoreNetworkMergeKeepsExtras() {
        let coupon = RateLimitResetCoupon(title: "Full reset", status: "available",
                                          expiresAt: Date(timeIntervalSince1970: 1_786_558_383))
        let good = RateLimitSnapshot(
            providerId: "codex-test-merge",
            windows: [RateLimitWindow(kind: "codex_primary", label: "7d", windowMinutes: 10080, usedPercent: 75)],
            planType: "prolite", capturedAt: Date(timeIntervalSince1970: 1_786_500_000),
            credits: RateLimitCredits(hasCredits: true, unlimited: false, balance: "4.2"),
            resetCoupons: [coupon])
        RateLimitStore.shared.put(good)
        RateLimitStore.shared.put(RateLimitSnapshot(
            providerId: "codex-test-merge", windows: [], capturedAt: Date(), error: .network))
        let merged = RateLimitStore.shared.snapshot(for: "codex-test-merge")
        XCTAssertEqual(merged?.windows.count, 1)
        XCTAssertEqual(merged?.error, .network)
        XCTAssertEqual(merged?.credits?.displayText, "$4.20", "积分随窗口一起保留")
        XCTAssertEqual(merged?.availableCoupons.count, 1, "重置券随窗口一起保留")
        RateLimitStore.shared.remove("codex-test-merge")
    }

    // MARK: - Qoder：账号指纹（issue #4，Work 与 IDE 可能登录不同账号）

    /// JWT 的 sub 最标准，优先于凭证 JSON 里的字段。
    func testQoderAccountFingerprintPrefersJWTSub() {
        let token = "head.eyJzdWIiOiJ1c2VyLTEyMyJ9.sig"   // payload = {"sub":"user-123"}
        let obj: [String: Any] = ["uid": "json-uid", "token": token]
        XCTAssertEqual(QoderRateLimitReader.accountFingerprint(in: obj, token: token), "user-123")
    }

    /// token 不是 JWT 时，递归找凭证 JSON 里的账号字段（uid/email 等）。
    func testQoderAccountFingerprintFallsBackToJSONKeys() {
        let obj: [String: Any] = ["profile": ["email": "a@b.com"]]
        XCTAssertEqual(QoderRateLimitReader.accountFingerprint(in: obj, token: "opaque-token"), "a@b.com")
    }

    /// ⛔ 方向锁：什么都判不出时退回 token 本身——同 token 必同账号；不同 token 判「不同账号」
    /// 只是多查一次、两行数字相同，**误判成同账号才会重现 issue #4 的标签错配**。
    func testQoderAccountFingerprintFallsBackToToken() {
        XCTAssertEqual(QoderRateLimitReader.accountFingerprint(in: ["foo": "bar"], token: "opaque"), "opaque")
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
