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
            serverId: nil
        )
        let updated = QwenWorkBillingRecord(
            amount: -14.1835,
            createdAt: first.createdAt,
            source: "网页版",
            detail: "—",
            origin: .billings,
            serverId: nil
        )
        let computer = QwenWorkBillingRecord(
            amount: -3,
            createdAt: Date(timeIntervalSince1970: 1_784_822_400),
            source: "电脑版",
            detail: "电脑端用量",
            origin: .computer,
            serverId: "2026-07-23"
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

    func testLoadsVersion2CacheWithoutAccountFingerprint() async throws {
        let store = QwenWorkBillingStore(fileURL: file)
        await store.replace(
            origin: .billings,
            with: [QwenWorkBillingRecord(
                amount: -2.5,
                createdAt: Date(timeIntervalSince1970: 1_784_862_095),
                source: "网页版",
                detail: "—",
                origin: .billings,
                serverId: nil
            )]
        )

        let raw = try Data(contentsOf: file)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        object["version"] = 2
        object.removeValue(forKey: "accountFingerprint")
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)

        let migrated = QwenWorkBillingStore(fileURL: file)
        let ledger = await migrated.cachedLedger()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].credits, 2.5, accuracy: 0.0001)
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
                serverId: nil
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

}
