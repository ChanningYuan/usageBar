import XCTest
import usageBarCore
@testable import usageBarProviders

final class QwenWorkBillingTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageBar-qwen-billing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("billings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func testParsesSignedBillingsAndSourceFallback() throws {
        let root = json("""
        {"data":[
          {"amount":-14.1835,"created_at":"2026-07-24T10:01:35+08:00","type":"对话",
           "consume_source":"web","detail":{"title":""}},
          {"amount":100,"created_at":"2026-07-24T08:24:41+08:00","type":"奖励",
           "detail":{"title":"每日奖励"}}
        ]}
        """)

        let rows = try XCTUnwrap(QwenWorkBillingStore.parseBillings(root))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].amount, -14.1835, accuracy: 0.0001)
        XCTAssertEqual(rows[0].spent, 14.1835, accuracy: 0.0001)
        XCTAssertEqual(rows[0].source, "web")
        XCTAssertEqual(rows[0].detail, "—")
        XCTAssertEqual(rows[1].spent, 0, "正数奖励不是积分消耗")
        XCTAssertEqual(rows[1].detail, "每日奖励")
        XCTAssertEqual(
            QwenWorkBillingStore.parseBillings(json("{\"data\":null}")),
            [],
            "官网兼容逻辑把 null 历史视为空集"
        )
    }

    func testParsesComputerDailyBreakdownAsSpend() throws {
        let root = json("""
        {"data":{"detail":{"title":"电脑端用量"},"daily_breakdown":[
          {"date":"2026-07-23","amount":3.25},
          {"date":"2026-07-24","amount":-2.5}
        ]}}
        """)

        let rows = try XCTUnwrap(QwenWorkBillingStore.parseComputer(root))
        XCTAssertEqual(rows.map(\.amount), [-3.25, -2.5])
        XCTAssertTrue(rows.allSatisfy { $0.origin == .computer && $0.source == "电脑版" })
        XCTAssertEqual(QwenWorkBillingStore.parseComputer(NSNull()), [])
    }

    func testReplacingMutableConversationRowDoesNotDoubleCount() async throws {
        let first = QwenWorkBillingRecord(
            amount: -7.1099,
            createdAt: Date(timeIntervalSince1970: 1_784_862_095),
            source: "网页版",
            detail: "—",
            origin: .billings,
            serverId: nil,
            type: "对话"
        )
        let updated = QwenWorkBillingRecord(
            amount: -14.1835,
            createdAt: first.createdAt,
            source: "网页版",
            detail: "—",
            origin: .billings,
            serverId: nil,
            type: "对话"
        )
        let computer = QwenWorkBillingRecord(
            amount: -3,
            createdAt: Date(timeIntervalSince1970: 1_784_822_400),
            source: "电脑版",
            detail: "电脑端用量",
            origin: .computer,
            serverId: "2026-07-23",
            type: "对话"
        )

        let store = QwenWorkBillingStore(fileURL: file)
        let firstObserved = Date(timeIntervalSince1970: 1_784_862_100)
        let secondObserved = Date(timeIntervalSince1970: 1_784_948_500)
        await store.replace(origin: .billings, with: [first], observedAt: firstObserved)
        await store.replace(origin: .computer, with: [computer], observedAt: firstObserved)
        await store.replace(origin: .billings, with: [updated], observedAt: secondObserved)
        await store.replace(
            origin: .billings,
            with: [updated],
            observedAt: secondObserved.addingTimeInterval(30)
        )
        await store.replace(origin: .billings, with: [], observedAt: secondObserved.addingTimeInterval(60))
        await store.replace(
            origin: .billings,
            with: [updated],
            observedAt: secondObserved.addingTimeInterval(90)
        )

        let ledger = await store.cachedLedger()
        XCTAssertEqual(ledger.count, 3,
                       "首轮两条 + 会话增长的一条差分；同值刷新或短暂缺席后重现都不能重复写")
        XCTAssertEqual(ledger.reduce(0) { $0 + $1.credits }, 17.1835, accuracy: 0.0001)
        XCTAssertEqual(ledger.last?.credits ?? 0, 7.0736, accuracy: 0.0001)
        XCTAssertEqual(ledger.last?.occurredAt, secondObserved,
                       "旧会话新增消耗必须归到观察到增长的周期，而不是旧 created_at")

        let reloaded = QwenWorkBillingStore(fileURL: file)
        let diskLedger = await reloaded.cachedLedger()
        XCTAssertEqual(diskLedger.count, 3, "积分差分流水必须持久化，离线/重启后仍可按周期统计")
        XCTAssertEqual(diskLedger.reduce(0) { $0 + $1.credits }, 17.1835, accuracy: 0.0001)
    }

    /// 老版本缓存必须整体丢弃，不能迁移。
    ///
    /// v1–v3 的流水是按「负数即消耗」算出来的，把「每日积分过期」记成了消耗；那几版的行又没存 `type`，
    /// 无法就地判断该剔除哪几条。服务端每次返回完整历史，丢掉重拉即可——留着只会一直错下去。
    func testDiscardsPreV4CacheBecauseItsLedgerCountedExpiryAsSpend() async throws {
        let store = QwenWorkBillingStore(fileURL: file)
        await store.replace(
            origin: .billings,
            with: [QwenWorkBillingRecord(
                amount: -2.5,
                createdAt: Date(timeIntervalSince1970: 1_784_862_095),
                source: "网页版",
                detail: "—",
                origin: .billings,
                serverId: nil,
                type: "对话"
            )]
        )

        for staleVersion in [1, 2, 3] {
            let raw = try Data(contentsOf: file)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: raw) as? [String: Any]
            )
            object["version"] = staleVersion
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)

            let reloaded = QwenWorkBillingStore(fileURL: file)
            let ledger = await reloaded.cachedLedger()
            XCTAssertTrue(ledger.isEmpty, "v\(staleVersion) 缓存含错误口径的流水，必须丢弃而不是迁移")
            let history = await reloaded.cachedHistory()
            XCTAssertFalse(history.isAvailable, "丢弃老缓存后回到「尚未同步」，等下一次刷新重建")
        }
    }

    /// ⛔ 回归锁：账单里的负数有两种，「每日积分过期」不是消耗。
    ///
    /// 初版拿「负数即消耗」当判据，本机实测今日消耗虚报 100（真实 0）、历史虚增 3.6 倍。
    /// 判据必须是白名单 `type == "对话"`——用排除法排掉已知类型的话，厂商将来新增一种负数类型
    /// （退款 / 扣罚…）会再次被误计，所以这里连「未知负数类型」一起断言。
    func testExpiryAndRewardRowsAreNotCountedAsSpend() throws {
        let root = json("""
        {"data":[
          {"amount":-0.7456,"created_at":"2026-07-31T14:01:10+08:00","type":"对话",
           "granularity":"session","source":"desktop","detail":{"title":""}},
          {"amount":-100,"created_at":"2026-08-04T00:00:00+08:00","type":"过期",
           "detail":{"title":"每日积分过期"}},
          {"amount":500,"created_at":"2026-08-04T10:54:45+08:00","type":"奖励",
           "detail":{"title":"限时活动赠送"}},
          {"amount":-42,"created_at":"2026-08-04T11:00:00+08:00","type":"某种新扣减",
           "detail":{"title":"厂商将来新增的类型"}}
        ]}
        """)

        let rows = try XCTUnwrap(QwenWorkBillingStore.parseBillings(root))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].spent, 0.7456, accuracy: 0.0001, "对话才是真实消耗")
        XCTAssertEqual(rows[1].spent, 0, "「过期」是没花完的赠送额度作废，不是用户消耗")
        XCTAssertEqual(rows[2].spent, 0, "「奖励」是入账")
        XCTAssertEqual(rows[3].spent, 0, "未知的负数类型也不算消耗——白名单，不是排除法")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.spent }, 0.7456, accuracy: 0.0001)
    }

    /// 电脑端按日汇总没有 type 字段，解析时必须补成「对话」，否则会被白名单判据整段漏算。
    func testComputerRowsAreTreatedAsConsumption() throws {
        let root = json("""
        {"data":{"detail":{"title":"电脑端用量"},"daily_breakdown":[{"date":"2026-07-23","amount":3.25}]}}
        """)
        let rows = try XCTUnwrap(QwenWorkBillingStore.parseComputer(root))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isConsumption)
        XCTAssertEqual(rows[0].spent, 3.25, accuracy: 0.0001)
    }

    /// ⛔ 回归锁：同一秒的多条账单不能互相覆盖，否则每刷新一次就多记一笔。
    ///
    /// 服务端同秒返回的多条行，created_at / source / detail 完全一样 → `identityKey` 相撞。
    /// 相撞后差分会拿第一条的金额当第二条的基线，差出非零 delta 并写流水，下次刷新再算一遍，
    /// **永远不收敛**。实测现场：一条 7-30 的旧行被写了 5 遍、每遍 0.3847，当天总额从 2.67 顶到 4.59。
    func testSameSecondRowsDoNotAccumulatePhantomLedgerEntries() async throws {
        let sameInstant = Date(timeIntervalSince1970: 1_785_477_561)
        func row(_ amount: Double) -> QwenWorkBillingRecord {
            QwenWorkBillingRecord(amount: amount, createdAt: sameInstant, source: "desktop",
                                  detail: "—", origin: .billings, serverId: nil, type: "对话")
        }
        // 同一秒两条不同金额的账单（服务端实测存在）
        let fetched = [row(-0.3847), row(-1.2789)]
        XCTAssertEqual(fetched[0].identityKey, fetched[1].identityKey,
                       "前提：这两条的 identityKey 本来就相同，所以必须靠序号区分")
        XCTAssertEqual(Set(QwenWorkBillingStore.indexedKeys(fetched)).count, 2,
                       "加了组内序号后必须变成两个不同的键")

        let store = QwenWorkBillingStore(fileURL: file)
        let base = Date(timeIntervalSince1970: 1_785_500_000)
        for i in 0..<5 {
            await store.replace(origin: .billings, with: fetched,
                                observedAt: base.addingTimeInterval(Double(i) * 300))
        }

        let ledger = await store.cachedLedger()
        XCTAssertEqual(ledger.count, 2, "反复刷新同样的数据不能写出多余流水（原 bug 会写 6 条）")
        XCTAssertEqual(ledger.reduce(0) { $0 + $1.credits }, 1.6636, accuracy: 0.0001,
                       "合计必须等于两条账单本身，不能随刷新次数增长")
        XCTAssertTrue(ledger.allSatisfy { $0.occurredAt == sameInstant },
                      "首次见到的行归到服务端时间，不该被记成「今天刚发生」")
    }

    /// ⛔ 回归锁：Hero 的周期总额必须等于「按会话」各行之和（在都能匹配上的前提下）。
    ///
    /// 0804 踩过两次「对不上」：
    /// 1. 同秒撞键写出幽灵流水 → Hero 虚高（见 `testSameSecondRows…`）；
    /// 2. gate 开启前的会话 token=0 被整条丢弃 → 它的积分匹配不上、也不在会话列表里 → 少 1.2329。
    ///    修法是保留 0-token 事件用于算会话区间，并让会话集合取 token 与积分的并集。
    func testSessionCreditsSumMatchesPeriodTotalIncludingZeroTokenSessions() throws {
        func at(_ s: String) -> Date { ISODateParser.parse(s)! }
        func event(_ session: String, _ ts: String, tokens: TokenBreakdown) -> QwenWorkUsageEvent {
            QwenWorkUsageEvent(sessionId: session, requestId: session + ts, timestamp: at(ts),
                               date: DailyAggregator.dateString(for: at(ts)),
                               model: "qmodel_latest", tokens: tokens)
        }
        let withTokens = TokenBreakdown(input: 5129, output: 58, cacheCreate5m: 0,
                                        cacheCreate1h: 0, cacheRead: 23168)
        let events = [
            // gate 开启后：有 token
            event("after-gate", "2026-08-04T13:08:22+08:00", tokens: withTokens),
            // gate 开启前：同样发生过请求，但 token 全 0（这条以前会被整条丢掉）
            event("before-gate", "2026-08-04T12:59:22+08:00", tokens: TokenBreakdown()),
        ]
        func entry(_ credits: Double, _ ts: String) -> QwenWorkCreditLedgerEntry {
            QwenWorkCreditLedgerEntry(credits: credits, occurredAt: at(ts),
                                      recordKey: ts, origin: .billings)
        }
        let ledger = [
            entry(1.2789, "2026-08-04T13:08:22+08:00"),
            entry(1.2329, "2026-08-04T12:59:22+08:00"),
        ]

        let detail = QwenWorkDetailScanner.compose(
            events: events, creditLedger: ledger, metas: [:],
            window: .today, weekStartMonday: true,
            now: at("2026-08-04T14:00:00+08:00"))

        XCTAssertEqual(detail.cost, 2.5118, accuracy: 0.0001, "Hero 周期总额")
        XCTAssertEqual(detail.sessions.count, 2, "只有 token 的和只有积分的会话都要列出来")
        XCTAssertEqual(detail.sessions.reduce(0) { $0 + $1.cost }, detail.cost, accuracy: 0.0001,
                       "各会话积分之和必须等于周期总额，否则界面上就是「数字对不上」")
        let zeroTokenSession = try XCTUnwrap(detail.sessions.first { $0.tokens.total == 0 })
        XCTAssertEqual(zeroTokenSession.cost, 1.2329, accuracy: 0.0001,
                       "gate 开启前的会话没有 token，但它确实花了积分，不能凭空消失")
        XCTAssertEqual(detail.tokens.total, withTokens.total,
                       "0-token 事件不能污染 token 统计，它只用于算会话区间")
    }

    /// 药丸「剩余」那颗的数据源：`/user/balance`，且格式要与官方页面一致（2,437.02）。
    func testParsesBalanceForQuotaPill() throws {
        XCTAssertEqual(
            QwenWorkBillingStore.parseBalance(
                json("{\"code\":\"ok\",\"data\":{\"balance\":2437.0181,\"freeze_credit\":0}}")) ?? 0,
            2437.0181, accuracy: 0.0001)
        XCTAssertEqual(
            QwenWorkBillingStore.parseBalance(json("{\"balance\":12}")) ?? 0, 12, accuracy: 0.0001)
        XCTAssertNil(QwenWorkBillingStore.parseBalance(json("{\"code\":\"ok\"}")))
        XCTAssertEqual(QwenWorkBillingStore.formatCredits(2437.0181), "2,437.02")
    }

    func testDistinguishesUnsyncedHistoryFromRealZero() async throws {
        let emptyStore = QwenWorkBillingStore(fileURL: file)
        let before = await emptyStore.cachedHistory()
        XCTAssertFalse(before.isAvailable)
        XCTAssertTrue(before.ledger.isEmpty)

        await emptyStore.replace(origin: .billings, with: [])
        let after = await emptyStore.cachedHistory()
        XCTAssertTrue(after.isAvailable, "成功同步到空历史是已知的 0，不是未知")
        XCTAssertTrue(after.ledger.isEmpty)
    }

    func testJWTAccountFingerprintIsStableAndAccountSwitchClearsLedger() async throws {
        func token(_ userId: String, nonce: String) -> String {
            let json = "{\"user_id\":\"\(userId)\",\"nonce\":\"\(nonce)\"}"
            let payload = Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "header.\(payload).signature"
        }

        let accountA = try XCTUnwrap(QwenWorkBillingStore.accountFingerprint(
            from: token("account-a", nonce: "one")
        ))
        XCTAssertEqual(
            accountA,
            QwenWorkBillingStore.accountFingerprint(from: token("account-a", nonce: "two")),
            "同一账号换 token 后 fingerprint 必须稳定"
        )
        let accountB = try XCTUnwrap(QwenWorkBillingStore.accountFingerprint(
            from: token("account-b", nonce: "one")
        ))
        XCTAssertNotEqual(accountA, accountB)

        let store = QwenWorkBillingStore(fileURL: file)
        await store.selectAccount(accountA)
        await store.replace(
            origin: .billings,
            with: [QwenWorkBillingRecord(
                amount: -9,
                createdAt: Date(timeIntervalSince1970: 1_784_862_095),
                source: "网页版",
                detail: "—",
                origin: .billings,
                serverId: nil,
                type: "对话"
            )]
        )
        let firstLedger = await store.cachedLedger()
        XCTAssertEqual(firstLedger.count, 1)

        await store.selectAccount(accountB)
        let switchedLedger = await store.cachedLedger()
        XCTAssertTrue(switchedLedger.isEmpty, "账号切换不能混入上一账号的积分")
    }

    func testDetailAggregatesExactSpendBySelectedPeriod() throws {
        func entry(_ credits: Double, _ timestamp: String) -> QwenWorkCreditLedgerEntry {
            QwenWorkCreditLedgerEntry(
                credits: credits,
                occurredAt: ISODateParser.parse(timestamp)!,
                recordKey: timestamp,
                origin: .billings
            )
        }
        let rows = [
            entry(10, "2026-07-20T09:00:00+08:00"),   // 本周一
            entry(5, "2026-07-23T17:00:00+08:00"),    // 本周四
            entry(20, "2026-07-19T17:00:00+08:00"),   // 上周日、本月内
        ]
        let now = try XCTUnwrap(ISODateParser.parse("2026-07-24T12:00:00+08:00"))

        let week = QwenWorkDetailScanner.compose(
            events: [],
            creditLedger: rows,
            metas: [:],
            window: .thisWeek,
            weekStartMonday: true,
            now: now
        )
        let month = QwenWorkDetailScanner.compose(
            events: [],
            creditLedger: rows,
            metas: [:],
            window: .thisMonth,
            weekStartMonday: true,
            now: now
        )

        XCTAssertEqual(week.cost, 15, accuracy: 0.0001)
        XCTAssertEqual(month.cost, 35, accuracy: 0.0001)
        XCTAssertTrue(week.costAvailable)
        XCTAssertEqual(week.tokens.total, 0,
                       "账单能覆盖 token gate 开启前的历史；详情页不应因 token=0 隐藏积分")

        let unsynced = QwenWorkDetailScanner.compose(
            events: [],
            creditLedger: [],
            creditsAvailable: false,
            metas: [:],
            window: .thisWeek,
            weekStartMonday: true,
            now: now
        )
        XCTAssertFalse(unsynced.costAvailable, "尚未同步不能伪装成真实 0 积分")
    }

    /// 积分挂回会话：账单行没有 session_id，只能按「本地会话时间区间 ⊇ 账单时间」匹配。
    ///
    /// 关键不变量：**匹配不中的钱不能消失**——周期总额始终按全部流水算，
    /// 所以「各会话之和 ≤ 周期总额」，差额就是没匹配上的部分。
    func testMatchesCreditsToSessionsByTimeAndKeepsUnmatchedInTotal() throws {
        func at(_ s: String) -> Date { ISODateParser.parse(s)! }
        let spans = [
            "session-a": (first: at("2026-07-31T13:58:00+08:00"), last: at("2026-07-31T14:02:00+08:00")),
            "session-b": (first: at("2026-07-31T15:00:00+08:00"), last: at("2026-07-31T15:10:00+08:00")),
        ]
        func entry(_ credits: Double, _ ts: String) -> QwenWorkCreditLedgerEntry {
            QwenWorkCreditLedgerEntry(credits: credits, occurredAt: at(ts),
                                      recordKey: ts, origin: .billings)
        }
        let ledger = [
            entry(0.75, "2026-07-31T14:01:10+08:00"),   // 落在 a 区间内
            entry(1.44, "2026-07-31T15:05:00+08:00"),   // 落在 b 区间内
            entry(0.36, "2026-07-31T14:03:00+08:00"),   // a 结束后 1 分钟 → 容差内，归 a
            entry(9.99, "2026-07-31T20:00:00+08:00"),   // 离任何会话都远 → 不归任何会话
        ]

        let matched = QwenWorkDetailScanner.matchCreditsToSessions(ledger, spans: spans)
        XCTAssertEqual(matched["session-a"] ?? 0, 1.11, accuracy: 0.0001, "区间内 + 容差内都归 a")
        XCTAssertEqual(matched["session-b"] ?? 0, 1.44, accuracy: 0.0001)
        XCTAssertEqual(matched.values.reduce(0, +), 2.55, accuracy: 0.0001,
                       "离群那条不该被硬塞给最近的会话")

        let total = ledger.reduce(0) { $0 + $1.credits }
        XCTAssertLessThan(matched.values.reduce(0, +), total,
                          "没匹配上的钱仍留在周期总额里，只是不挂到任何会话")
        XCTAssertTrue(QwenWorkDetailScanner.matchCreditsToSessions(ledger, spans: [:]).isEmpty,
                      "没有任何本地会话时（如 gate 开启前）全部落未匹配，不能乱挂")
    }
}
