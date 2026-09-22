import XCTest
import usageBarCore

@testable import usageBarProviders

/// Qoder 额度响应解析（`QoderRateLimitReader.snapshot(fromQuota:now:)`）。
/// 两个样本都是真机实测原文：personal（2026-07-14 本机探针）、teams（2026-07-15 同事探针）。
/// 核心回归点：**percentage 字段两种量纲**（personal 0–100 / teams 0–1）——解析必须用 used/total 自算，
/// 否则 teams 用满的席位显示成 1%（v0.3.24 线上 bug）。
final class QoderQuotaTests: XCTestCase {

    private func parse(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
    }

    func testTeamsPercentageIsFractionScale() {
        // 同事 teams 账号实测：席位 6000/6000 用满，API 却回 percentage=1.0（0–1 量纲）
        let obj = parse("""
        {"userId":"019cf7c1","userType":"teams","usageType":"credits",
         "totalUsagePercentage":1.0,"isQuotaExceeded":false,"expiresAt":1784736000000,
         "userQuota":{"total":6000.0,"used":6000.0,"remaining":0.0,"percentage":1.0,"unit":"credits"},
         "orgResourcePackage":{"used":6551.0,"remaining":7449.0,"percentage":0.47,"unit":"credits","cap":14000.0,"available":true},
         "isPlanQuotaProrated":false}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.planType, "teams")
        XCTAssertEqual(snap.windows.count, 2)   // 席位套餐 + 组织资源包
        XCTAssertEqual(snap.windows[0].label, "套餐")
        XCTAssertEqual(snap.windows[0].usedPercent, 100, accuracy: 0.01)   // 不是 1
        XCTAssertEqual(snap.windows[0].detail, "6,000/6,000")
        XCTAssertEqual(snap.windows[0].resetsAt,
                       Date(timeIntervalSince1970: 1_784_736_000))         // 2026-07-23 00:00 +0800
        XCTAssertEqual(snap.windows[1].label, "组织共享")
        XCTAssertEqual(snap.windows[1].usedPercent, 46.79, accuracy: 0.01) // 不是 0.47
        XCTAssertEqual(snap.windows[1].detail, "6,551/14,000")
        XCTAssertNil(snap.windows[1].resetsAt)   // 购买制，无刷新日期（expiresAt 归属套餐）
    }

    func testPersonalPercentageIsPercentScale() {
        // 2026-07-14 本机探针实测：personal 账号 percentage 是 0–100 量纲，自算结果应与其一致
        let obj = parse("""
        {"userType":"personal_standard","usageType":"credits","totalUsagePercentage":37.0,
         "userQuota":{"total":5000,"used":1850,"remaining":3150,"percentage":37,"unit":"credits"},
         "expiresAt":253402214400000}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.windows.count, 1)    // personal 无 orgResourcePackage
        XCTAssertEqual(snap.windows[0].label, "月")
        XCTAssertEqual(snap.windows[0].usedPercent, 37, accuracy: 0.01)
        XCTAssertEqual(snap.windows[0].detail, "1,850/5,000")
        XCTAssertNil(snap.windows[0].resetsAt)   // year-9999 哨兵 = 永不过期
    }

    func testClaudePlanLabelFromLocalConfig() {
        // ~/.claude.json oauthAccount 明文推导付费档（2026-07-15 本机实测字段）
        func label(_ tier: [String: Any]) -> String? {
            ClaudeStatuslineReader.planLabel(fromConfig: ["oauthAccount": tier])
        }
        XCTAssertEqual(label(["organizationRateLimitTier": "default_claude_max_5x"]), "Max 5x")
        XCTAssertEqual(label(["organizationRateLimitTier": "default_claude_max_20x"]), "Max 20x")
        XCTAssertEqual(label(["organizationType": "claude_pro"]), "Pro")
        // userRateLimitTier 优先于组织档
        XCTAssertEqual(label(["userRateLimitTier": "claude_max_20x",
                              "organizationRateLimitTier": "default_claude_max_5x"]), "Max 20x")
        XCTAssertNil(label(["organizationType": "enterprise_weird"]))   // 认不出宁缺别乱标
        XCTAssertNil(ClaudeStatuslineReader.planLabel(fromConfig: [:]))
    }

    // MARK: - v0.3.37：CLI 行的归属与文案（外部用户 2026-08-28 报的误报）

    /// 2026-08-28 本机 qodercli 1.1.21 `status -o json` 实测原文
    private static let statusJSON = """
    {"logged_in":true,"version":"1.1.21","allow_byok":0,"username":"原晨瑜",
     "email":"user@example.com",
     "avatar_url":"https://qoder.com/users/019efc88-48a7-708b-b5ca-80643e713b67/default/avatars",
     "user_type":"personal_standard"}
    """

    /// 2026-08-28 本机 `~/.qoder/logs/runs/…/qodercli.log` 实测原文（含前后噪声行）
    private static let logSample = """
    2026-08-28T10:08:37.981+08:00 INFO  debug.message [qoder-server-request] --> operation=getQuotaUsage method=GET url=https://openapi.qoder.sh/api/v2/quota/usage
    2026-08-28T10:08:38.870+08:00 INFO  debug.message [qoder-server-request] <-- operation=getQuotaUsage status=200 duration=889ms
    2026-08-28T10:08:38.871+08:00 INFO  debug.message [qoderApi] GET https://openapi.qoder.sh/api/v2/quota/usage response: {"userId":"019efc88-48a7-708b-b5ca-80643e713b67","userType":"personal_standard","usageType":"credits","totalUsagePercentage":37.0,"expiresAt":253402214400000,"userQuota":{"total":5000,"used":1850,"remaining":3150,"percentage":37,"unit":"credits"}}
    2026-08-28T10:08:39.000+08:00 INFO  debug.message [tui] ready
    """

    func testStatusJSONParsesLoginAndAccountId() {
        let id = QoderCliQuotaReader.parseStatus(Data(Self.statusJSON.utf8))
        XCTAssertEqual(id?.loggedIn, true)
        XCTAssertEqual(id?.userType, "personal_standard")
        // 账号 id 从 avatar_url 的 /users/<uuid>/ 段取——这是判「Work 凭证是不是同一个账号」的依据
        XCTAssertEqual(id?.userId, "019efc88-48a7-708b-b5ca-80643e713b67")
    }

    func testCliLogYieldsQuotaWithRealCaptureTime() throws {
        let hit = QoderCliQuotaReader.parseLatestQuota(in: Self.logSample)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.userId, "019efc88-48a7-708b-b5ca-80643e713b67")
        XCTAssertNil(hit?.snapshot.error)
        XCTAssertEqual(hit?.snapshot.windows.first?.detail, "1,850/5,000")
        // ⚠️ capturedAt 必须是日志里那条的真实时刻，不能粉饰成 now——否则「更新于 3d 前」会骗人
        let capturedAt = try XCTUnwrap(hit?.snapshot.capturedAt)
        XCTAssertEqual(capturedAt.timeIntervalSince1970,
                       1_787_882_918.871, accuracy: 0.01)   // 2026-08-28 10:08:38.871 +0800
    }

    func testCliLogTakesTheLatestEntryNotTheFirst() {
        // 一个 run 里打了两次额度，必须取**后**那条
        let later = "2026-08-28T11:00:00.000+08:00 INFO  debug.message [qoderApi] GET "
            + "https://openapi.qoder.sh/api/v2/quota/usage response: "
            + #"{"userId":"019efc88-48a7-708b-b5ca-80643e713b67","userType":"personal_standard","#
            + #""expiresAt":253402214400000,"userQuota":{"total":5000,"used":4000,"remaining":1000}}"#
        let hit = QoderCliQuotaReader.parseLatestQuota(in: Self.logSample + "\n" + later)
        XCTAssertEqual(hit?.snapshot.windows.first?.detail, "4,000/5,000")
    }

    func testMalformedLogNeverThrowsOrLies() {
        // 日志格式没有兼容承诺——认不出就当没有，绝不因此报错
        XCTAssertNil(QoderCliQuotaReader.parseLatestQuota(in: "毫无关系的日志"))
        XCTAssertNil(QoderCliQuotaReader.parseLatestQuota(
            in: "2026-08-28T10:08:38.871+08:00 quota/usage response: {\"userQuota\": 断掉了"))
        // 有响应体但没有行首时间戳 → 宁可不用，也不谎报采集时间
        XCTAssertNil(QoderCliQuotaReader.parseLatestQuota(
            in: "quota/usage response: {\"userQuota\":{\"total\":5000,\"used\":10}}"))
    }

    func testSameAccountOnlyRejectsWhenProvablyDifferent() {
        let cli = "019efc88-48a7-708b-b5ca-80643e713b67"
        // 相等 → 同账号
        XCTAssertTrue(QoderCliQuotaReader.sameAccount(credential: cli, cliUserId: cli))
        // 两边都是 UUID 且不等 → **确凿**不同账号，不许代领
        XCTAssertFalse(QoderCliQuotaReader.sameAccount(
            credential: "019cf7c1-0000-4000-8000-000000000000", cliUserId: cli))
        // 指纹是 email / 数字 uid / token 原文 → 形态不可比，判不出就沿用老行为（不回归）
        XCTAssertTrue(QoderCliQuotaReader.sameAccount(credential: "a@b.com", cliUserId: cli))
        XCTAssertTrue(QoderCliQuotaReader.sameAccount(credential: "88123", cliUserId: cli))
    }

    func testAvatarURLWithoutUUIDGivesNoAccountId() {
        // 认不出就给 nil——nil 的语义是「判不出」，会让 sameAccount 放行，方向安全
        XCTAssertNil(QoderCliQuotaReader.userId(fromAvatarURL: "https://qoder.com/users/me/avatars"))
        XCTAssertNil(QoderCliQuotaReader.userId(fromAvatarURL: "https://qoder.com/avatars.png"))
    }

    /// ⭐️ 本次线上 bug 的回归锁：外部用户 2026-08-28 报的原始场景。
    /// QoderWork 凭证过期（401）、Qoder CLI 登录完好 —— CLI 行**绝不能**再说「登录凭证已失效」。
    func testWorkCredentialExpiredMustNotBlameTheCLI() {
        let loggedInCli = QoderCliQuotaReader.Identity(
            loggedIn: true, userId: "019efc88-48a7-708b-b5ca-80643e713b67",
            userType: "personal_standard")
        let snap = QoderRateLimitReader.cliFallback(
            identity: loggedInCli, hasWork: true, hasIde: false, now: Date())

        XCTAssertEqual(snap.providerId, "qoder-cli")
        XCTAssertEqual(snap.error, .quotaUnavailable)          // 中性态
        XCTAssertNotEqual(snap.error, .credentialUnavailable)  // ← 就是这一条在线上说错了话
        // sourceLabel 指向 CLI 自己——UI 据此说「Qoder CLI 已登录 · 暂无额度数据」
        // （文案本体按项目约定在 UI 层 `QuotaFormat.errorText`，Core 测试够不到，这里锁它的输入契约）
        XCTAssertEqual(snap.sourceLabel, "Qoder CLI")
    }

    func testCliNotLoggedInSaysSoPlainly() {
        let out = QoderCliQuotaReader.Identity(loggedIn: false, userId: nil, userType: nil)
        let snap = QoderRateLimitReader.cliFallback(
            identity: out, hasWork: true, hasIde: true, now: Date())
        XCTAssertEqual(snap.error, .notLoggedIn)
        XCTAssertEqual(snap.sourceLabel, "Qoder CLI")   // → UI:「Qoder CLI 未登录 ·」
    }

    /// CLI 没装 / status 跑不起来 → 沿用老结论，但必须点名是**谁**的凭证不可用
    func testWithoutCliFallsBackButNamesTheSource() {
        let work = QoderRateLimitReader.cliFallback(
            identity: nil, hasWork: true, hasIde: false, now: Date())
        XCTAssertEqual(work.error, .credentialUnavailable)
        XCTAssertEqual(work.sourceLabel, "QoderWork")   // → UI:「QoderWork 额度凭证已失效 ·」

        let ide = QoderRateLimitReader.cliFallback(
            identity: nil, hasWork: false, hasIde: true, now: Date())
        XCTAssertEqual(ide.sourceLabel, "Qoder IDE")

        // 一份凭证都没有 → 没有来源可点名，UI 退回原来的笼统文案
        let none = QoderRateLimitReader.cliFallback(
            identity: nil, hasWork: false, hasIde: false, now: Date())
        XCTAssertNil(none.sourceLabel)
    }

    /// 401 退避：连败要拉长间隔，用户主动重试立即解除
    func testAuthFailureBacksOffAndUserRetryClearsIt() {
        let t0 = Date()
        QoderRateLimitReader.clearBackoff()
        XCTAssertFalse(QoderRateLimitReader.isBackedOff(.work, now: t0))

        QoderRateLimitReader.noteAuthFailure(.work, now: t0)
        XCTAssertTrue(QoderRateLimitReader.isBackedOff(.work, now: t0.addingTimeInterval(60)))
        XCTAssertFalse(QoderRateLimitReader.isBackedOff(.work, now: t0.addingTimeInterval(6 * 60)))
        // 退避是**按来源**的，别把 IDE 一起连坐
        XCTAssertFalse(QoderRateLimitReader.isBackedOff(.ide, now: t0.addingTimeInterval(60)))

        QoderRateLimitReader.noteAuthFailure(.work, now: t0)   // 第二次连败 → 10 分钟
        XCTAssertTrue(QoderRateLimitReader.isBackedOff(.work, now: t0.addingTimeInterval(6 * 60)))

        QoderRateLimitReader.clearBackoff()                    // 用户点「重试」
        XCTAssertFalse(QoderRateLimitReader.isBackedOff(.work, now: t0))
    }

    // MARK: - issue #11：三类额度独立，不能被零套餐额度截断

    private static var organizationPackage: [String: Any] { [
        "cap": 76000, "used": 13629, "remaining": 62371,
        "percentage": 0.18, "available": true, "unit": "credits",
    ] }

    func testOrganizationPackageSurvivesZeroOrMissingPlanQuota() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for providerId in ["qoder-cli", "qoder-ide"] {
            for quota: [String: Any]? in [["total": 0, "used": 0], nil] {
                var obj: [String: Any] = ["userType": "teams",
                                         "orgResourcePackage": Self.organizationPackage]
                obj["userQuota"] = quota
                let snap = QoderRateLimitReader.snapshot(
                    fromQuota: obj, now: now, providerId: providerId, sourceLabel: "Qoder IDE")
                XCTAssertNil(snap.error)
                XCTAssertEqual(snap.providerId, providerId)
                XCTAssertEqual(snap.planType, "teams")
                XCTAssertEqual(snap.sourceLabel, "Qoder IDE")
                XCTAssertEqual(snap.capturedAt, now)
                XCTAssertEqual(snap.windows.count, 1)
                let window = try XCTUnwrap(snap.windows.first)
                XCTAssertEqual(window.kind, "pack")
                XCTAssertEqual(window.label, "组织共享")
                XCTAssertEqual(window.used, 13629)
                XCTAssertEqual(window.total, 76000)
                XCTAssertEqual(window.usedPercent, 17.9328947368, accuracy: 0.000001)
                XCTAssertEqual(window.detail, "13,629/76,000")
                XCTAssertNil(window.resetsAt)
            }
        }
    }

    func testExhaustedOrganizationPackageRemainsVisible() throws {
        let obj = parse("""
        {"userType":"teams","userQuota":{"total":0,"used":0},
         "orgResourcePackage":{"cap":76000,"used":76000,"remaining":0,"available":false}}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.windows.count, 1)
        let window = try XCTUnwrap(snap.windows.first)
        XCTAssertEqual(window.usedPercent, 100)
        XCTAssertEqual(window.detail, "76,000/76,000")
    }

    func testAddOnQuotaWorksWithoutPlanOrOrganizationPackage() throws {
        let obj = parse("""
        {"userType":"personal_standard","expiresAt":1784736000000,
         "addOnQuota":{"total":1500,"used":450,"remaining":1050,"percentage":0.3}}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.windows.count, 1)
        let window = try XCTUnwrap(snap.windows.first)
        XCTAssertEqual(window.kind, "addon")
        XCTAssertEqual(window.label, "加购")
        XCTAssertEqual(window.usedPercent, 30)
        XCTAssertEqual(window.used, 450)
        XCTAssertEqual(window.total, 1500)
        XCTAssertEqual(window.detail, "450/1,500")
        XCTAssertNil(window.resetsAt, "套餐重置时间不能挂到加购额度上")
    }

    func testAllThreeQuotaBucketsRetainTheirOwnNumbersAndReset() {
        var obj = parse("""
        {"userType":"teams","expiresAt":1784736000000,
         "userQuota":{"total":6000,"used":6000,"percentage":1},
         "addOnQuota":{"total":1500,"used":1500,"remaining":0}}
        """)
        obj["orgResourcePackage"] = Self.organizationPackage
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.windows.map(\.kind), ["monthly", "addon", "pack"])
        XCTAssertEqual(snap.windows.map(\.label), ["套餐", "加购", "组织共享"])
        XCTAssertEqual(snap.windows.map(\.detail), ["6,000/6,000", "1,500/1,500", "13,629/76,000"])
        XCTAssertEqual(snap.windows.map(\.resetsAt), [Date(timeIntervalSince1970: 1_784_736_000), nil, nil])
        XCTAssertEqual(snap.windows.map(\.usedPercent), [100, 100, 13629.0 / 76000 * 100])
    }

    func testMalformedBucketsDoNotInventUsageOrHideValidOrganizationPackage() {
        let invalidBuckets: [[String: Any]] = [
            [:], ["total": 100], ["total": 100, "used": NSNull()],
            ["total": "100", "used": 10], ["total": 100, "used": "10"],
            ["total": true, "used": 0], ["total": 100, "used": false],
            ["total": -100, "used": 10], ["total": 100, "used": -1],
            ["total": Double.infinity, "used": 0], ["total": 100, "used": Double.nan],
        ]
        for bucket in invalidBuckets {
            let obj: [String: Any] = ["userType": "teams", "userQuota": bucket,
                                     "addOnQuota": bucket, "orgResourcePackage": Self.organizationPackage]
            let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
            XCTAssertNil(snap.error)
            XCTAssertEqual(snap.windows.map(\.kind), ["pack"])

            var invalidPack = bucket
            invalidPack["cap"] = invalidPack.removeValue(forKey: "total")
            let empty = QoderRateLimitReader.snapshot(fromQuota: ["orgResourcePackage": invalidPack], now: Date())
            XCTAssertTrue(empty.windows.isEmpty)
            XCTAssertEqual(empty.error, .noQuotaData)
        }
    }

    func testEmptyResponseKeepsContextWithoutClaimingAnUnsupportedAccount() {
        for obj: [String: Any] in [[:], ["userType": "teams"]] {
            let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date(), sourceLabel: "Qoder IDE")
            XCTAssertTrue(snap.windows.isEmpty)
            XCTAssertEqual(snap.error, .noQuotaData)
            XCTAssertEqual(snap.planType, obj["userType"] as? String)
            XCTAssertEqual(snap.sourceLabel, "Qoder IDE")
        }
    }

    func testZeroAndOverLimitUsageRemainValidNumbers() {
        let obj = parse("""
        {"userQuota":{"total":6000,"used":0},
         "addOnQuota":{"total":1500,"used":1600},
         "orgResourcePackage":{"cap":100,"used":0,"available":true}}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.windows.map(\.usedPercent), [0, 100, 0])
        XCTAssertEqual(snap.windows.map(\.detail), ["0/6,000", "1,600/1,500", "0/100"])
    }

    func testLatestCliQuotaWithOnlyOrganizationPackageDoesNotResurrectOldPlan() throws {
        let latest = """
        2026-09-22T15:45:38.000+08:00 quota/usage response: {"userType":"teams","userQuota":{"total":0,"used":0},"orgResourcePackage":{"cap":76000,"used":13629,"remaining":62371,"available":true}}
        """
        let hit = try XCTUnwrap(QoderCliQuotaReader.parseLatestQuota(in: Self.logSample + "\n" + latest))
        XCTAssertNil(hit.snapshot.error)
        XCTAssertEqual(hit.snapshot.planType, "teams")
        XCTAssertEqual(hit.snapshot.windows.map(\.kind), ["pack"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(hit.snapshot.capturedAt, formatter.date(from: "2026-09-22T15:45:38.000+08:00"))
    }

    func testCommunityNoQuota() {
        // 免费版 total=0 → 无信用点额度概念
        let obj = parse("""
        {"userType":"community","userQuota":{"total":0,"used":0,"remaining":0,"percentage":0,"unit":"credits"}}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertEqual(snap.error, .noQuotaData)
        XCTAssertTrue(snap.windows.isEmpty)
        XCTAssertEqual(snap.planType, "community")
    }
}
