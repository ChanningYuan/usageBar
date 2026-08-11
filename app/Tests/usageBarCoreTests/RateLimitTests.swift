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

    // MARK: - Codex：多桶 rate_limits（issue #6，2026-08-03 上游变更）

    /// fixture 是 2026-08-04 本机 `~/.codex/sessions` 的真实数据（issue #6 原文）。
    private static let codexNow = Date(timeIntervalSince1970: 1_786_000_000)
    private var sparkRL: [String: Any] {
        ["limit_id": "codex_bengalfox", "limit_name": "GPT-5.3-Codex-Spark",
         "primary": ["used_percent": 0.0, "window_minutes": 10080, "resets_at": 1_786_415_386],
         "secondary": NSNull(), "plan_type": NSNull()]
    }
    private var mainRL: [String: Any] {
        ["limit_id": "codex", "limit_name": NSNull(),
         "primary": ["used_percent": 13.0, "window_minutes": 10080, "resets_at": 1_786_100_000],
         "secondary": NSNull(), "plan_type": "prolite"]
    }

    /// ⛔ 核心锁：最近会话都是 Spark（entries 里 Spark 桶最新）时，主套餐桶不能被覆盖——两桶全展示、主桶在前。
    func testCodexMultiBucketSparkNotOverridingMain() {
        let entries = [
            CodexRateLimitReader.RLEntry(rl: sparkRL, ts: Date(timeIntervalSince1970: 1_785_999_000), file: 0),  // 最新：Spark 会话
            CodexRateLimitReader.RLEntry(rl: mainRL, ts: Date(timeIntervalSince1970: 1_785_900_000), file: 1),   // 较旧：主模型会话
        ]
        let (windows, plan) = CodexRateLimitReader.bucketize(entries, now: Self.codexNow)
        XCTAssertEqual(windows.count, 2, "两个桶都要展示，Spark 不能盖掉主套餐")
        XCTAssertEqual(windows[0].label, "7d", "主桶排最前、保持现有样式")
        XCTAssertEqual(windows[0].usedPercent, 13.0)
        XCTAssertNil(windows[0].scopeModel)
        XCTAssertEqual(windows[1].label, "Spark", "专属桶用 limit_name 短名（类比 Claude 的 Fable chip）")
        XCTAssertEqual(windows[1].usedPercent, 0.0)
        XCTAssertEqual(windows[1].scopeModel, "Spark")
        XCTAssertEqual(plan, "prolite", "plan_type 是账号级的，Spark 桶里是 null，要从主桶取")
    }

    /// 旧格式（无 limit_id 字段，2026-08-03 之前的 session）归入主桶，向后兼容。
    func testCodexOldFormatWithoutLimitIdIsMainBucket() {
        let old: [String: Any] = [
            "primary": ["used_percent": 21.0, "window_minutes": 10080, "resets_at": 1_786_100_000],
            "secondary": NSNull(), "plan_type": "prolite",
        ]
        let (windows, _) = CodexRateLimitReader.bucketize(
            [CodexRateLimitReader.RLEntry(rl: old, ts: Date(timeIntervalSince1970: 1_785_999_000))], now: Self.codexNow)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "7d")
        XCTAssertNil(windows[0].scopeModel, "旧格式是主桶，不能当成专属桶")
    }

    /// resets_at 已过 = 那个窗口已结束，百分比失效 → 过期桶剔除，不展示死数据。
    func testCodexExpiredBucketDropped() {
        var expiredMain = mainRL
        expiredMain["primary"] = ["used_percent": 13.0, "window_minutes": 10080,
                                  "resets_at": 1_785_916_855]   // < now，已过期
        let entries = [
            CodexRateLimitReader.RLEntry(rl: sparkRL, ts: Date(timeIntervalSince1970: 1_785_999_000), file: 0),
            CodexRateLimitReader.RLEntry(rl: expiredMain, ts: Date(timeIntervalSince1970: 1_785_000_000), file: 1),
        ]
        let (windows, plan) = CodexRateLimitReader.bucketize(entries, now: Self.codexNow)
        XCTAssertEqual(windows.count, 1, "过期的主桶要剔除")
        XCTAssertEqual(windows[0].label, "Spark")
        XCTAssertEqual(plan, "prolite", "plan_type 仍可从过期桶里捞（账号级，不随窗口过期）")
    }

    /// 全部桶都过期（长期没用 Codex）→ 退回只显示最新一桶，对齐旧行为：显示最后已知状态而非整行消失。
    func testCodexAllExpiredFallsBackToNewest() {
        var expiredSpark = sparkRL
        expiredSpark["primary"] = ["used_percent": 0.0, "window_minutes": 10080,
                                   "resets_at": 1_785_916_855]
        var expiredMain = mainRL
        expiredMain["primary"] = ["used_percent": 13.0, "window_minutes": 10080,
                                  "resets_at": 1_785_916_855]
        let entries = [
            CodexRateLimitReader.RLEntry(rl: expiredSpark, ts: Date(timeIntervalSince1970: 1_785_999_000), file: 0),
            CodexRateLimitReader.RLEntry(rl: expiredMain, ts: Date(timeIntervalSince1970: 1_785_000_000), file: 1),
        ]
        let (windows, _) = CodexRateLimitReader.bucketize(entries, now: Self.codexNow)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Spark", "退回最新一桶（entries 首个）")
    }

    /// ⛔ 0.147 格式锁（2026-08-11 本机实测）：cli 0.147 起 `limit_id` 恒为 "codex"、`limit_name` 恒
    /// null——两池只能靠 `resets_at` 区分、靠会话 `model` 命名。主桶挑选：出现文件多的是共享主池。
    func testCodex147SameLimitIdSplitByResetsAt() {
        // 本机真实数据：主池 48%（resets 08-18 14:03，gpt-5.6-sol 会话在写）；
        // Spark 池 0%（resets 08-18 21:26 = 首次用 Spark + 7d，gpt-5.3-codex-spark 会话在写）
        let spark147: [String: Any] = [
            "limit_id": "codex", "limit_name": NSNull(),
            "primary": ["used_percent": 0.0, "window_minutes": 10080, "resets_at": 1_786_415_386],
            "secondary": NSNull(), "plan_type": "prolite",
        ]
        let main147: [String: Any] = [
            "limit_id": "codex", "limit_name": NSNull(),
            "primary": ["used_percent": 48.0, "window_minutes": 10080, "resets_at": 1_786_100_000],
            "secondary": NSNull(), "plan_type": "prolite",
        ]
        let entries = [
            CodexRateLimitReader.RLEntry(rl: spark147, ts: Date(timeIntervalSince1970: 1_785_999_000),
                                         model: "gpt-5.3-codex-spark", file: 0),   // 最新：Spark 会话
            CodexRateLimitReader.RLEntry(rl: main147, ts: Date(timeIntervalSince1970: 1_785_990_000),
                                         model: "gpt-5.6-sol", file: 1),           // 主池被多个会话写
            CodexRateLimitReader.RLEntry(rl: main147, ts: Date(timeIntervalSince1970: 1_785_900_000),
                                         model: "gpt-5.6-sol", file: 2),
        ]
        let (windows, plan) = CodexRateLimitReader.bucketize(entries, now: Self.codexNow)
        XCTAssertEqual(windows.count, 2, "limit_id 相同也要按 resets_at 分成两池")
        XCTAssertEqual(windows[0].label, "7d", "主池（出现文件多）排最前、保持现有样式")
        XCTAssertEqual(windows[0].usedPercent, 48.0)
        XCTAssertEqual(windows[1].label, "Spark", "专属池 limit_name 缺失时用会话模型短名")
        XCTAssertEqual(windows[1].usedPercent, 0.0)
        XCTAssertEqual(windows[1].scopeModel, "Spark")
        XCTAssertEqual(plan, "prolite")
    }

    /// ⛔ 顶替锁（2026-08-11 实测翻车修正）：主池手动重置/滚动后 `resets_at` 会跳变，旧窗口实例
    /// 即使时间上没过期也是死数据（当天 08-15/08-17/08-18 三代实例并存，前两代 15%/9% 都是幽灵）。
    /// 同池（模型共现判定）只显示最新实例。
    func testCodex147SupersededInstanceHidden() {
        func rl(_ pct: Double, resets: Int) -> [String: Any] {
            ["limit_id": "codex", "limit_name": NSNull(),
             "primary": ["used_percent": pct, "window_minutes": 10080, "resets_at": resets],
             "secondary": NSNull(), "plan_type": "prolite"]
        }
        let entries = [
            // 旧实例（15%，resets 在未来）——被顶替的死数据；同模型 → 同池
            CodexRateLimitReader.RLEntry(rl: rl(15, resets: 1_786_200_000),
                                         ts: Date(timeIntervalSince1970: 1_785_800_000),
                                         model: "gpt-5.6-sol", file: 2),
            // 当前实例（48%，ts 最新）
            CodexRateLimitReader.RLEntry(rl: rl(48, resets: 1_786_400_000),
                                         ts: Date(timeIntervalSince1970: 1_785_999_000),
                                         model: "gpt-5.6-sol", file: 0),
        ]
        let (windows, _) = CodexRateLimitReader.bucketize(entries, now: Self.codexNow)
        XCTAssertEqual(windows.count, 1, "同池的旧窗口实例必须被顶替隐藏，不能当成另一个池展示")
        XCTAssertEqual(windows[0].label, "7d")
        XCTAssertEqual(windows[0].usedPercent, 48.0, "显示的必须是 ts 最新的实例")
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
