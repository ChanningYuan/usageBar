import CommonCrypto
import XCTest
import usageBarCore
@testable import usageBarProviders

/// v0.3.38：千问办公额度三类（每日 / 周期 / 长期）与网页令牌线的回归锁。
/// 样本全部来自 2026-09-08 / 09-12 本机探针实测（spec 0910 §6），别改成编的数。
final class QwenWorkQuotaTests: XCTestCase {
    private func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private let accountContext = """
    {"code":"ok","data":{"plan":{"pid":"subscription-cn-free","name":"Free","user_type":"personal","is_personal_version":true},
     "quota":{"total":null,"used":null,"remaining":2037.0181,"exceeded":false}}}
    """

    private let wallets = """
    {"code":"ok","data":{"active_wallets":{"wallets":[
      {"balance":100,"valid_to":"2026-09-13T00:00:00+08:00"},
      {"balance":1937.0181,"valid_to":"2026-10-23T14:53:47.132+08:00"}],"total":2,"page_size":20,"page_number":1},
     "daily_credits":{"total_balance":100},"expiring_soon":{"count":0,"total_balance":0,"wallets":[]},
     "longterm_credits":{"total_balance":0},"monthly_credits":{"total_balance":1937.0181}}}
    """

    private let plans = """
    {"code":"ok","data":[
      {"pid":"qwen-office-enterprise","name":"企业版","values":{"daily_trial_credits":150,"starter_credits":300,"monthly_credits":2000}},
      {"pid":"subscription-cn-free","name":"Free","values":{"daily_trial_credits":100,"starter_credits":2000,"monthly_credits":0}}]}
    """

    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-12T10:00:00+08:00")! }

    // MARK: 解析

    func testParsesAccountContextQuotaAndPlan() throws {
        let root = json(accountContext)
        let quota = try XCTUnwrap(QwenWorkBillingStore.parseAccountQuota(root))
        XCTAssertEqual(quota.remaining ?? 0, 2037.0181, accuracy: 0.0001)
        XCTAssertNil(quota.total, "个人版 total 为 null，不能编一个分母出来")
        XCTAssertNil(quota.used)
        let plan = try XCTUnwrap(QwenWorkBillingStore.parsePlan(root))
        XCTAssertEqual(plan.pid, "subscription-cn-free")
        XCTAssertEqual(plan.name, "Free")
        XCTAssertEqual(plan.isPersonal, true)
        XCTAssertTrue(plan.isFreeTier)
    }

    func testParsesWalletsIntoThreeBucketsAndPacks() throws {
        let w = try XCTUnwrap(QwenWorkBillingStore.parseWallets(json(wallets)))
        XCTAssertEqual(w.daily, 100, accuracy: 0.0001)
        XCTAssertEqual(w.monthly, 1937.0181, accuracy: 0.0001)
        XCTAssertEqual(w.longterm, 0, accuracy: 0.0001)
        XCTAssertEqual(w.wallets.count, 2)
        XCTAssertEqual(w.wallets[0].balance, 100, accuracy: 0.0001)
        XCTAssertNotNil(w.wallets[0].validTo)
        XCTAssertEqual(w.daily + w.monthly + w.longterm, 2037.0181, accuracy: 0.0001,
                       "三类之和 = 官方「剩余可用」大字，逐位闭合")
    }

    func testParsesPlanCatalogByPid() throws {
        let catalog = try XCTUnwrap(QwenWorkBillingStore.parsePlanCatalog(json(plans)))
        XCTAssertEqual(catalog["subscription-cn-free"]?.dailyTrialCredits, 100)
        XCTAssertEqual(catalog["subscription-cn-free"]?.starterCredits, 2000)
        XCTAssertEqual(catalog["qwen-office-enterprise"]?.dailyTrialCredits, 150)
    }

    // MARK: 三类推断

    func testFreeTierCategoriesUseDailyAndStarterGrants() throws {
        let w = try XCTUnwrap(QwenWorkBillingStore.parseWallets(json(wallets)))
        let plan = try XCTUnwrap(QwenWorkBillingStore.parsePlan(json(accountContext)))
        let quota = QwenWorkBillingStore.parseAccountQuota(json(accountContext))
        let catalog = try XCTUnwrap(QwenWorkBillingStore.parsePlanCatalog(json(plans)))
        let cats = QwenWorkBillingStore.categories(wallets: w, plan: plan, accountQuota: quota, catalog: catalog, now: now)
        XCTAssertEqual(cats.map(\.id), ["daily", "period", "longterm"])

        let daily = cats[0]
        XCTAssertEqual(daily.grant, 100)
        XCTAssertEqual(daily.remaining, 100, accuracy: 0.0001)
        XCTAssertEqual(daily.used ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(daily.resetVerb, "清零")
        XCTAssertNotNil(daily.resetsAt, "每日包到期 = 今晚 00:00")
        XCTAssertEqual(daily.packs.map(\.title), ["每日赠送"])

        let period = cats[1]
        XCTAssertEqual(period.grant, 2000, "免费档周期包 = 注册赠送，分母查 starter_credits")
        XCTAssertEqual(period.used ?? -1, 62.9819, accuracy: 0.0001,
                       "2000 − 1937.0181 = 62.9819，与 0804 账单闭合出的月钱包已用一致")
        XCTAssertEqual(period.resetVerb, "到期")
        XCTAssertEqual(period.packs.count, 1)
        XCTAssertEqual(period.packs[0].title, "注册赠送 (starter)")
        XCTAssertEqual(period.packs[0].grant, 2000)

        let longterm = cats[2]
        XCTAssertNil(longterm.grant, "长期没有「额度」概念")
        XCTAssertEqual(longterm.remaining, 0, accuracy: 0.0001)
        XCTAssertTrue(longterm.packs.isEmpty)
    }

    func testGrantDroppedWhenRemainingExceedsIt() {
        // 活动日每日包被顶到 500（分母仍是 100）→ 分母作废，只显示「剩 500」
        let w = QwenWorkWallets(daily: 500, monthly: 1937.0181, longterm: 0, wallets: [
            QwenWorkWallet(balance: 500, validTo: now.addingTimeInterval(14 * 3600)),
            QwenWorkWallet(balance: 1937.0181, validTo: now.addingTimeInterval(40 * 86400)),
        ])
        let catalog = ["subscription-cn-free": QwenWorkPlanValues(dailyTrialCredits: 100, starterCredits: 2000, monthlyCredits: 0)]
        let plan = QwenWorkPlan(pid: "subscription-cn-free", name: "Free", isPersonal: true)
        let cats = QwenWorkBillingStore.categories(wallets: w, plan: plan, accountQuota: nil, catalog: catalog, now: now)
        XCTAssertNil(cats[0].grant)
        XCTAssertNil(cats[0].used)
        XCTAssertEqual(cats[1].grant, 2000)
    }

    func testMultiplePeriodPacksLoseGrantAndUseGenericTitle() {
        let w = QwenWorkWallets(daily: 100, monthly: 2437.0181, longterm: 0, wallets: [
            QwenWorkWallet(balance: 100, validTo: now.addingTimeInterval(14 * 3600)),
            QwenWorkWallet(balance: 500, validTo: now.addingTimeInterval(3 * 86400)),
            QwenWorkWallet(balance: 1937.0181, validTo: now.addingTimeInterval(40 * 86400)),
        ])
        let catalog = ["subscription-cn-free": QwenWorkPlanValues(dailyTrialCredits: 100, starterCredits: 2000, monthlyCredits: 0)]
        let plan = QwenWorkPlan(pid: "subscription-cn-free", name: "Free", isPersonal: true)
        let cats = QwenWorkBillingStore.categories(wallets: w, plan: plan, accountQuota: nil, catalog: catalog, now: now)
        XCTAssertNil(cats[1].grant, "2437 > 2000：充值/活动叠加，分母作废")
        XCTAssertEqual(cats[1].packs.count, 2)
        XCTAssertTrue(cats[1].packs.allSatisfy { $0.title == "积分包" && $0.grant == nil },
                      "多个包时接口分不出谁是谁，不许猜")
        XCTAssertNotNil(cats[1].resetsAt)
        XCTAssertEqual(cats[1].resetsAt, now.addingTimeInterval(3 * 86400), "到期取最近的一个包")
    }

    func testEnterpriseSeatUsesAccountQuotaTotalAndUsed() {
        // 9/7 公司机器实测：可用 18444.85 / 20000，累计已用 1554.15
        let quota = QwenWorkAccountQuota(remaining: 18444.85, total: 20000, used: 1554.15)
        let plan = QwenWorkPlan(pid: "qwen-office-enterprise", name: "企业基础版", isPersonal: false)
        let cats = QwenWorkBillingStore.categories(wallets: nil, plan: plan, accountQuota: quota, catalog: [:], now: now)
        XCTAssertEqual(cats.count, 1)
        XCTAssertEqual(cats[0].id, "period")
        XCTAssertEqual(cats[0].grant, 20000)
        XCTAssertEqual(cats[0].used ?? -1, 1554.15, accuracy: 0.0001, "企业席位直接用服务端给的累计已用")
    }

    // MARK: 网页令牌

    /// 造一张只有 exp 的假 JWT（不验签，只解析 payload）
    private func fakeJWT(exp: TimeInterval, aud: String = "user") -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["aud": aud, "exp": Int(exp), "sub": "x"])
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\(b64).sig"
    }

    func testJWTExpiryAndUsability() {
        let soon = fakeJWT(exp: now.timeIntervalSince1970 + 30)
        let later = fakeJWT(exp: now.timeIntervalSince1970 + 48 * 3600)
        XCTAssertFalse(QwenWorkJWT.isUsable(soon, now: now), "剩 30 秒当过期")
        XCTAssertTrue(QwenWorkJWT.isUsable(later, now: now))
        XCTAssertEqual(QwenWorkJWT.audience(later), "user")
        XCTAssertNil(QwenWorkJWT.expiry("not-a-jwt"))
    }

    func testExtractsTokenFromCurlCookieHeaderAndBareJWT() {
        let jwt = fakeJWT(exp: now.timeIntervalSince1970 + 3600)
        let curl = """
        curl --url 'https://qwenwork.cn/user/wallets' \\
          -H 'accept: application/json' \\
          -b 'cna=abc; ory_hydra_session=MTc4; token=\(jwt); tfstk=xyz' \\
          -H 'x-client-source: desktop'
        """
        XCTAssertEqual(QwenWorkWebTokenExtractor.extract(from: curl), jwt)
        XCTAssertEqual(QwenWorkWebTokenExtractor.extract(from: "Cookie: a=1; token=\(jwt)"), jwt)
        XCTAssertEqual(QwenWorkWebTokenExtractor.extract(from: "  \(jwt)\n"), jwt)
        XCTAssertEqual(QwenWorkWebTokenExtractor.extract(from: "Authorization: Bearer \(jwt)"), jwt)
        XCTAssertNil(QwenWorkWebTokenExtractor.extract(from: "nothing here"))
        XCTAssertNil(QwenWorkWebTokenExtractor.extract(from: ""))
    }

    /// Chrome cookie 解密：v10 + AES-128-CBC（IV 16 空格）+ PKCS7；Chrome ≥130 明文前有 32 字节 host 哈希。
    func testDecryptsChromeCookieWithAndWithoutHostHashPrefix() throws {
        let key = Data((0..<16).map { UInt8($0 * 7 + 3) })
        let jwt = fakeJWT(exp: now.timeIntervalSince1970 + 3600)
        let plainNew = Data(repeating: 0xAB, count: 32) + Data(jwt.utf8)
        let plainOld = Data(jwt.utf8)
        for plain in [plainNew, plainOld] {
            let cipher = try encrypt(plain, key: key)
            let blob = Data("v10".utf8) + cipher
            XCTAssertEqual(ChromeCookieReader.decryptCookieValue(blob, key: key), jwt)
        }
        XCTAssertNil(ChromeCookieReader.decryptCookieValue(Data("v10garbage".utf8), key: key))
        XCTAssertNil(ChromeCookieReader.decryptCookieValue(Data("v20".utf8), key: key), "非 v10 前缀不认")
    }

    private func encrypt(_ plain: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: 16)
        let capacity = plain.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            plain.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, 16, iv, inBuf.baseAddress, plain.count,
                            outBuf.baseAddress, capacity, &moved)
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        return out.prefix(moved)
    }

    // MARK: 状态：有缓存 ≠ 已同步

    func testHistoryIsUnavailableUntilWebLineSucceedsInThisProcess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageBar-qwen-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("billings.json")

        let first = QwenWorkBillingStore(fileURL: file)
        await first.replace(origin: .billings, with: [], observedAt: now)
        // 第二个实例从磁盘读缓存：有文件，但本进程没同步过 → 不可用（v0.3.38 之前这里是 true，导致 0.0000 假数）
        let second = QwenWorkBillingStore(fileURL: file)
        let history = await second.cachedHistory()
        XCTAssertFalse(history.isAvailable)
        XCTAssertEqual(history.lastSyncAt, now, "缓存里的「最后同步时刻」要跟着落盘，UI 才能标「截至 HH:mm」")
        let quota = await second.quota(now: now)
        XCTAssertNil(quota.todaySpent, "网页线没同步就不给「今日已用」")
    }

    func testQuotaSeedProducesThreeCategoriesAndTotal() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageBar-qwen-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QwenWorkBillingStore(fileURL: dir.appendingPathComponent("b.json"))
        let w = try XCTUnwrap(QwenWorkBillingStore.parseWallets(json(wallets)))
        let plan = try XCTUnwrap(QwenWorkBillingStore.parsePlan(json(accountContext)))
        let catalog = try XCTUnwrap(QwenWorkBillingStore.parsePlanCatalog(json(plans)))
        await store.seedForTesting(wallets: w, plan: plan, accountQuota: QwenWorkBillingStore.parseAccountQuota(json(accountContext)),
                                   catalog: catalog, balance: 2037.0181, webSession: .off)
        let quota = await store.quota(now: now)
        XCTAssertEqual(quota.remainingTotal ?? 0, 2037.0181, accuracy: 0.0001)
        XCTAssertEqual(quota.planName, "Free")
        XCTAssertEqual(quota.categories.count, 3)
        XCTAssertEqual(quota.webSession, .off)
        XCTAssertNil(quota.error)
    }
}
