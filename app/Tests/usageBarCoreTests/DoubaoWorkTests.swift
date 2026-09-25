import CommonCrypto
import CryptoKit
import SQLite3
import XCTest
import usageBarCore
@testable import usageBarProviders

/// 豆包工作（v0.3.45）：接口解析、翻页、镜像合并、账本写入与「列表 = Hero = 分模型 = 分会话」一致性。
/// 样本结构取自 2026-09-24 本机实测（标题、用户 id 已换成占位值）。
final class DoubaoWorkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageBar-doubao-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func item(_ id: String, title: String = "会话A", model: String = "Auto",
                      at seconds: TimeInterval, credits: Double) -> DoubaoWorkUsageItem {
        DoubaoWorkUsageItem(itemId: "D1#{10001}#{Q:\(id)}", title: title, model: model,
                            occurredAt: Date(timeIntervalSince1970: seconds),
                            credits: credits, creditsText: String(format: "%.2f", credits), source: "豆包订阅")
    }

    // MARK: - 额度

    func testParsesQuotaWindowsAsDisplayStringsAndIdleSession() throws {
        let body = data("""
        {"code":0,"data":{
          "window_limit_section":{"entitlement_count":1,"usage_exhausted":false,"window_limit_groups":[
            {"feature_group":"general","window_limits":[
              {"window_type":2,"total_amount":"2,100","used_amount":"17","used_percent":0,
               "less_than_one_percent":true,"start_time":1790158238528,"end_time":1790328468376},
              {"window_type":1,"total_amount":"735","used_amount":"0","used_percent":0,
               "less_than_one_percent":false,"start_time":0,"end_time":0}
            ]}]},
          "current_subscription":{"is_gift":true,"end_time":1790328468376,"merchant_user_id":"10001",
            "display":{"short_name":"标准套餐","product_name":"个人订阅"}},
          "campaign_benefit_info":{"benefit_end_time":1792920468376,"campaign_tag":4}
        }}
        """)
        XCTAssertEqual(DoubaoWorkAPI.classify(status: 200, data: body), .ok(body))
        let quota = try XCTUnwrap(DoubaoWorkAPI.parseQuota(body))
        XCTAssertEqual(quota.windows.map(\.type), [1, 2], "当前时段在前")

        let session = quota.windows[0]
        XCTAssertNil(session.endTime, "end_time = 0：往前 5 小时没用过，还没开始计时")
        XCTAssertEqual(session.usedText, "0")
        XCTAssertEqual(session.total, 735)

        let weekly = quota.windows[1]
        XCTAssertEqual(weekly.usedText, "17")
        XCTAssertEqual(weekly.totalText, "2,100", "展示串原样保留")
        XCTAssertEqual(weekly.total, 2100, "数值剥千分位")
        XCTAssertTrue(weekly.lessThanOnePercent)
        XCTAssertEqual(weekly.endTime, Date(timeIntervalSince1970: 1_790_328_468.376))

        XCTAssertEqual(quota.plan, DoubaoWorkPlan(name: "标准套餐", isGift: true,
                                                   endTime: Date(timeIntervalSince1970: 1_792_920_468.376)),
                       "活动权益到期（10-25）优先于订阅本期结束（09-25），与 App「免费体验至」一致")
        let account = try XCTUnwrap(quota.accountHash)
        XCTAssertFalse(account.contains("10001"), "账号只存单向哈希")
        XCTAssertEqual(account, DoubaoWorkAPI.accountHash("10001"))
    }

    func testPlanEndFallsBackToSubscriptionEndWithoutCampaign() throws {
        let body = data("""
        {"code":0,"data":{"window_limit_section":{"window_limit_groups":[]},
          "current_subscription":{"is_gift":false,"end_time":1790328468376,"display":{"short_name":"专业套餐"}}}}
        """)
        let plan = try XCTUnwrap(DoubaoWorkAPI.parseQuota(body)?.plan)
        XCTAssertEqual(plan.endTime, Date(timeIntervalSince1970: 1_790_328_468.376), "没有活动权益就用订阅本期结束")
        XCTAssertFalse(plan.isGift)
        XCTAssertEqual(plan.name, "专业套餐")
    }

    func testQuotaWithoutUsedAmountIsNotZero() throws {
        // 不带 aid（或消费版的 aid）时窗口里没有已用 / 总额：是「拿不到」，不是 0
        let body = data("""
        {"code":0,"data":{"window_limit_section":{"window_limit_groups":[{"feature_group":"general","window_limits":[
          {"window_type":1,"used_percent":0,"less_than_one_percent":false,"start_time":0,"end_time":0}]}]}}}
        """)
        let quota = try XCTUnwrap(DoubaoWorkAPI.parseQuota(body))
        XCTAssertNil(quota.windows[0].usedText)
        XCTAssertNil(quota.windows[0].total)
        XCTAssertNil(quota.plan)
        XCTAssertNil(quota.accountHash)
    }

    func testClassifiesLoginExpiredAndFailures() {
        let expired = data(#"{"code":710012001,"msg":"登录已过期，请重新登录","data":{}}"#)
        XCTAssertEqual(DoubaoWorkAPI.classify(status: 200, data: expired), .loggedOut,
                       "登录过期时 HTTP 仍是 200，要看业务码")
        XCTAssertEqual(DoubaoWorkAPI.classify(status: 401, data: Data()), .loggedOut)
        XCTAssertEqual(DoubaoWorkAPI.classify(status: 500, data: data(#"{"code":0,"data":{}}"#)), .failure)
        XCTAssertEqual(DoubaoWorkAPI.classify(status: 200, data: data(#"{"code":123,"data":{}}"#)), .failure)
        XCTAssertEqual(DoubaoWorkAPI.classify(status: 200, data: data("<html>")), .failure)
    }

    // MARK: - 明细

    func testParsesTimelineSkippingResetRowsAndKeepsCursor() throws {
        let body = data("""
        {"code":0,"data":{"has_more":true,"next_cursor":"v4.abc","entries":[
          {"entry_type":1,"usage":{"display_name":"查一下下载文件夹","item_id":"D1#{10001}#{Q:1}",
            "model_display_name":"Auto","occurred_at_ms":1790231931198,
            "quota_source":{"display_name":"豆包订阅","display_text":"0.54","quota_source_code":"doubao_personal_vip_quota"}}},
          {"entry_type":2,"reset":{"display_text":"7天重置","occurred_at_ms":1787736468698,"reset_id":"r"}},
          {"entry_type":1,"usage":{"display_name":"","item_id":"D1#{10001}#{Q:2}",
            "model_display_name":"豆包 2.1 Turbo","occurred_at_ms":1790231000000,
            "quota_source":{"display_name":"豆包订阅","display_text":"<0.01"}}},
          {"entry_type":1,"usage":{"display_name":"大任务","item_id":"D1#{10001}#{Q:3}",
            "model_display_name":"Auto","occurred_at_ms":1790230000000,
            "quota_source":{"display_name":"豆包订阅","display_text":"1,234.50"}}},
          {"entry_type":1,"usage":{"display_name":"坏行","item_id":"D1#{10001}#{Q:4}",
            "model_display_name":"Auto","occurred_at_ms":1790229000000,
            "quota_source":{"display_name":"豆包订阅","display_text":"—"}}}
        ]}}
        """)
        let page = try XCTUnwrap(DoubaoWorkAPI.parseTimeline(body))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "v4.abc")
        XCTAssertEqual(page.oldest, Date(timeIntervalSince1970: 1_787_736_468.698), "判停要算上重置分隔行")
        XCTAssertEqual(page.items.map(\.itemId), ["D1#{10001}#{Q:1}", "D1#{10001}#{Q:2}", "D1#{10001}#{Q:3}"],
                       "重置行没有 usage、解析不了的积分不编数，都跳过")
        XCTAssertEqual(page.items[0].credits, 0.54, accuracy: 1e-9)
        XCTAssertEqual(page.items[0].source, "豆包订阅")
        XCTAssertEqual(page.items[1].title, "(无标题会话)")
        XCTAssertEqual(page.items[1].credits, 0.01, accuracy: 1e-9, "<0.01 按上界记，免得显示成 0")
        XCTAssertEqual(page.items[1].creditsText, "<0.01")
        XCTAssertEqual(page.items[2].credits, 1234.5, accuracy: 1e-9)
    }

    func testNumberParsing() {
        XCTAssertEqual(DoubaoWorkAPI.number("2,100"), 2100)
        XCTAssertEqual(DoubaoWorkAPI.number("<1"), 1)
        XCTAssertEqual(DoubaoWorkAPI.number(" 0.97 "), 0.97)
        XCTAssertNil(DoubaoWorkAPI.number(""))
        XCTAssertNil(DoubaoWorkAPI.number("—"))
        XCTAssertNil(DoubaoWorkAPI.number("-3"))
    }

    // MARK: - 翻页

    private func page(_ items: [DoubaoWorkUsageItem], more: Bool, next: String?, oldest: TimeInterval) -> DoubaoWorkTimelinePage {
        DoubaoWorkTimelinePage(items: items, hasMore: more, nextCursor: next,
                               oldest: Date(timeIntervalSince1970: oldest))
    }

    func testFullSyncPagesToTheEnd() async {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let pages = [
            "": page([item("1", at: 1_790_290_000, credits: 1)], more: true, next: "c1", oldest: 1_790_290_000),
            "c1": page([item("2", at: 1_789_000_000, credits: 2)], more: true, next: "c2", oldest: 1_789_000_000),
            "c2": page([item("3", at: 1_788_000_000, credits: 3)], more: false, next: nil, oldest: 1_788_000_000),
        ]
        let result = await DoubaoWorkStore.collectTimeline(fullSync: true, now: now) { pages[$0] }
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.items.count, 3, "首次同步拿满服务端的 30 天")
    }

    func testIncrementalSyncStopsOnceOlderThanHorizon() async {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let pages = [
            "": page([item("1", at: 1_790_290_000, credits: 1)], more: true, next: "c1", oldest: 1_790_290_000),
            // 这一页最早一行已早于 48 小时 → 再往前都是终值，停
            "c1": page([item("2", at: 1_790_000_000, credits: 2)], more: true, next: "c2", oldest: 1_790_000_000),
            "c2": page([item("3", at: 1_789_000_000, credits: 3)], more: false, next: nil, oldest: 1_789_000_000),
        ]
        let result = await DoubaoWorkStore.collectTimeline(fullSync: false, now: now) { pages[$0] }
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.items.map(\.itemId), ["D1#{10001}#{Q:1}", "D1#{10001}#{Q:2}"])
    }

    func testFailedPageKeepsWhatWasFetchedButIsIncomplete() async {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let first = page([item("1", at: 1_790_290_000, credits: 1)], more: true, next: "c1", oldest: 1_790_290_000)
        let result = await DoubaoWorkStore.collectTimeline(fullSync: true, now: now) { $0.isEmpty ? first : nil }
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.items.count, 1)
    }

    func testPagingIsCapped() async {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let endless = page([item("x", at: 1_790_290_000, credits: 1)], more: true, next: "again", oldest: 1_790_290_000)
        let result = await DoubaoWorkStore.collectTimeline(fullSync: true, now: now, maxPages: 3) { _ in endless }
        XCTAssertEqual(result.items.count, 3, "服务端一直说还有下一页也不能死循环")
    }

    // MARK: - 镜像

    func testMergeOverwritesGrowingValueWithoutDuplicating() async throws {
        let file = directory.appendingPathComponent("doubao-work.json")
        let store = DoubaoWorkStore(fileURL: file, dataDirectory: directory)
        // 任务跑的过程中同一笔会原地变大（实测 0.47 → 0.54），按消息编号覆盖
        let first = await store.merge([item("1", at: 1_790_231_931.198, credits: 0.47)])
        let grown = await store.merge([item("1", at: 1_790_231_931.198, credits: 0.54)])
        let same = await store.merge([item("1", at: 1_790_231_931.198, credits: 0.54)])
        XCTAssertTrue(first)
        XCTAssertTrue(grown)
        XCTAssertFalse(same, "同值不算变化")
        let all = await store.allItems()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].credits, 0.54, accuracy: 1e-9)
    }

    func testMirrorRoundTripKeepsMillisecondsSoReloadIsNotAChange() async throws {
        let file = directory.appendingPathComponent("doubao-work.json")
        let original = item("1", at: 1_790_231_931.198, credits: 0.54)
        await DoubaoWorkStore(fileURL: file, dataDirectory: directory).seedForTesting([original])

        let reloaded = DoubaoWorkStore(fileURL: file, dataDirectory: directory)
        let all = await reloaded.allItems()
        XCTAssertEqual(all, [original])
        let changed = await reloaded.merge([original])
        XCTAssertFalse(changed, "毫秒丢了的话，读回来的笔与新拉的笔永远不相等，每轮都会被当成有变化")
    }

    // MARK: - 账本（真跑 provider 刷新，锁「列表 = Hero = 分模型 = 分会话」）

    func testProviderWritesLedgerAndDetailTotalsAgree() async throws {
        let file = directory.appendingPathComponent("doubao-work.json")
        let store = DoubaoWorkStore(fileURL: file, dataDirectory: directory)
        // 2026-09-24（北京时间）三笔 + 09-13 一笔；「回复我ok」两轮在同一会话
        let items = [
            item("1", title: "回复我ok", at: 1_790_150_000, credits: 0.20),
            item("2", title: "回复我ok", at: 1_790_150_060, credits: 0.19),
            item("3", title: "调研任务", at: 1_790_160_000, credits: 12.56),
            item("4", title: "看下载文件夹", model: "豆包 2.1 Turbo", at: 1_789_307_788, credits: 8.78),
        ]
        await store.seedForTesting(items)
        let ledger = FileMtimeCache()
        let provider = DoubaoWorkProvider(store: store, ledger: ledger)

        let records = try await provider.fetchDailyRecords()
        _ = try await provider.fetchDailyRecords()   // 每轮都跑：幂等，不翻倍
        XCTAssertEqual(records.map(\.token), Array(repeating: 0, count: records.count), "豆包工作没有 token")
        let entries = await ledger.allEntries()
        XCTAssertEqual(entries.count, 4, "每笔一条账本记录，重复刷新不翻倍")
        XCTAssertTrue(entries.allSatisfy { $0.filePath.hasPrefix(DoubaoWorkProvider.ledgerPrefix) })
        XCTAssertTrue(entries.allSatisfy { $0.recordsMatchDetails(provider: "doubao-work") })

        let details = await ledger.details(forProvider: "doubao-work")
        let detail = LedgerDetailAggregator.aggregate(
            providerId: "doubao-work", details: details, window: .all,
            now: Date(timeIntervalSince1970: 1_790_200_000))
        let expected = items.reduce(0) { $0 + $1.credits }
        XCTAssertEqual(detail.tokens.total, 0)
        XCTAssertEqual(detail.cost, expected, accuracy: 1e-9, "Hero = 全部积分")
        XCTAssertEqual(detail.models.reduce(0) { $0 + $1.cost }, expected, accuracy: 1e-9, "分模型合计 = Hero")
        XCTAssertEqual(detail.sessions.reduce(0) { $0 + $1.cost }, expected, accuracy: 1e-9, "分会话合计 = Hero")
        XCTAssertEqual(detail.sessions.count, 3, "同名会话的两轮合成一行")
        XCTAssertEqual(detail.sessions.map(\.title), ["调研任务", "看下载文件夹", "回复我ok"],
                       "token 全 0 时按积分从大到小排")
        XCTAssertEqual(detail.models.map(\.modelId), ["Auto", "豆包 2.1 Turbo"])
    }

    func testGrowingItemUpdatesLedgerInPlace() async throws {
        let store = DoubaoWorkStore(fileURL: directory.appendingPathComponent("m.json"), dataDirectory: directory)
        let ledger = FileMtimeCache()
        let provider = DoubaoWorkProvider(store: store, ledger: ledger)
        await store.seedForTesting([item("1", at: 1_790_231_931, credits: 0.47)])
        _ = try await provider.fetchDailyRecords()
        await store.seedForTesting([item("1", at: 1_790_231_931, credits: 0.54)])
        _ = try await provider.fetchDailyRecords()
        let details = await ledger.details(forProvider: "doubao-work")
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details[0].nativeCost ?? 0, 0.54, accuracy: 1e-9, "同一笔涨了就覆盖，不是追加")
    }

    // MARK: - 请求参数

    func testRequestContextReadsDeviceIdAndAlwaysSendsAid() throws {
        let localState = directory.appendingPathComponent("Local State")
        try data(#"{"aha":{"device":{"device_id":"1234567890123456"}},"browser":{}}"#).write(to: localState)
        XCTAssertEqual(DoubaoWorkAPI.RequestContext.deviceId(localState: localState), "1234567890123456")

        let context = DoubaoWorkAPI.RequestContext(appVersion: "2.27.15", chromiumVersion: "147.0.7727.149",
                                                   deviceId: "1234567890123456")
        let query = Dictionary(uniqueKeysWithValues: context.queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["aid"], "1044603", "aid 决定能不能拿到额度数字")
        XCTAssertEqual(query["fp"], "verify_1234567890123456")
        XCTAssertEqual(query["pc_version"], "2.27.15")
        XCTAssertNil(query["msToken"], "防刷令牌属于凭据，实测也不需要")

        let bare = DoubaoWorkAPI.RequestContext(appVersion: nil, chromiumVersion: nil, deviceId: nil)
        let bareNames = Set(bare.queryItems.map(\.name))
        XCTAssertTrue(bareNames.contains("aid"))
        XCTAssertFalse(bareNames.contains("device_id"), "读不到就不带，不编")

        let request = try XCTUnwrap(DoubaoWorkAPI.request(path: DoubaoWorkAPI.overviewPath, body: Data("{}".utf8),
                                                          cookie: "sessionid=x", context: context))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertFalse(request.httpShouldHandleCookies, "cookie 自己拼，不让 URLSession 的 cookie 罐掺和")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionid=x")
    }

    // MARK: - 额度快照（主列表药丸 / 详情页额度模块）

    private func status(_ error: DoubaoWorkSyncError? = nil, quota: DoubaoWorkQuota? = nil,
                        fetchedAt: Date? = nil) -> DoubaoWorkSyncStatus {
        DoubaoWorkSyncStatus(quota: quota, quotaFetchedAt: fetchedAt, lastSyncAt: fetchedAt,
                             error: error, itemsChanged: false)
    }

    private var sampleQuota: DoubaoWorkQuota {
        DoubaoWorkQuota(windows: [
            DoubaoWorkWindow(type: 1, usedText: "0", totalText: "735", usedPercent: 0,
                             lessThanOnePercent: false, endTime: nil),
            DoubaoWorkWindow(type: 2, usedText: "17", totalText: "2,100", usedPercent: 0,
                             lessThanOnePercent: true, endTime: Date(timeIntervalSince1970: 1_790_328_468.376)),
        ], plan: DoubaoWorkPlan(name: "标准套餐", isGift: true, endTime: Date(timeIntervalSince1970: 1_790_328_468.376)),
        accountHash: "h")
    }

    func testSnapshotMapsWindowsToPillsWithPendingSession() throws {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let fetched = Date(timeIntervalSince1970: 1_790_299_000)
        let snap = DoubaoWorkQuotaSnapshot.make(status(quota: sampleQuota, fetchedAt: fetched), now: now)
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.providerId, "doubao-work")
        XCTAssertEqual(snap.sourceLabel, "豆包工作")
        XCTAssertEqual(snap.planType, "标准套餐")
        XCTAssertEqual(snap.headline, "赠送至 9-25")
        XCTAssertEqual(snap.capturedAt, fetched, "陈旧判定按额度真正拿到的时间算")
        XCTAssertEqual(snap.windows.map(\.label), ["当前时段", "近7天"])

        let session = snap.windows[0]
        XCTAssertEqual(session.valueText, "已用 0/735")
        XCTAssertNil(session.resetsAt)
        XCTAssertEqual(session.pendingText, "开始使用后计时", "往前 5 小时没用过：照官方文案，不自己编重置时间")
        XCTAssertTrue(session.isPending)
        XCTAssertEqual(session.windowMinutes, 300)
        XCTAssertEqual(session.notes, ["5 小时窗口 · 额度 735 · 已用 0"])

        let weekly = snap.windows[1]
        XCTAssertEqual(weekly.valueText, "已用 17/2100", "药丸里不加千分位")
        XCTAssertEqual(weekly.notes, ["7 天窗口 · 额度 2,100 · 已用 17"], "详情页小字保留服务端原串")
        XCTAssertEqual(weekly.usedPercent, 0.5, "不到 1% 用 0.5 表示，显示成「<1%」")
        XCTAssertEqual(RateLimitWindow.percentText(weekly.usedPercent), "<1%")
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_790_328_468.376))
        XCTAssertNil(weekly.pendingText)
        XCTAssertFalse(weekly.isPending)
    }

    func testSnapshotReplacesPillsWithReasonWhenCredentialsFail() {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let cases: [(DoubaoWorkSyncError, RateLimitError)] = [
            (.loggedOut, .credentialUnavailable), (.authDenied, .authDenied), (.notInstalled, .notLoggedIn),
        ]
        for (error, expected) in cases {
            // 即使手里有上次的额度，也不拿旧数字充数：药丸位换成一行原因 + 入口
            let snap = DoubaoWorkQuotaSnapshot.make(status(error, quota: sampleQuota, fetchedAt: now), now: now)
            XCTAssertEqual(snap.windows, [], "\(error)")
            XCTAssertEqual(snap.error, expected, "\(error)")
            XCTAssertEqual(snap.sourceLabel, "豆包工作")
        }
    }

    func testSnapshotKeepsLastQuotaOnNetworkFailure() {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let fetched = Date(timeIntervalSince1970: 1_790_200_000)
        let stale = DoubaoWorkQuotaSnapshot.make(status(.network, quota: sampleQuota, fetchedAt: fetched), now: now)
        XCTAssertEqual(stale.windows.count, 2, "网络抖一下不抹掉额度")
        XCTAssertNil(stale.error)
        XCTAssertEqual(stale.capturedAt, fetched, "超过 20 分钟界面会自动置灰并写「更新于 x 前」")

        let never = DoubaoWorkQuotaSnapshot.make(status(.network), now: now)
        XCTAssertEqual(never.windows, [])
        XCTAssertEqual(never.error, .network)
    }

    func testWindowWithoutNumbersIsNotDrawnAsZero() {
        let noNumbers = DoubaoWorkQuota(windows: [
            DoubaoWorkWindow(type: 1, usedText: nil, totalText: nil, usedPercent: 0, lessThanOnePercent: false, endTime: nil),
        ], plan: nil, accountHash: nil)
        let snap = DoubaoWorkQuotaSnapshot.make(status(quota: noNumbers, fetchedAt: Date()), now: Date())
        XCTAssertEqual(snap.windows, [])
        XCTAssertEqual(snap.error, .noQuotaData)
        XCTAssertNil(snap.headline)
    }

    func testPercentTextAndPendingFieldBackwardCompatibility() throws {
        XCTAssertEqual(RateLimitWindow.percentText(0), "0%")
        XCTAssertEqual(RateLimitWindow.percentText(0.4), "<1%")
        XCTAssertEqual(RateLimitWindow.percentText(1), "1%")
        XCTAssertEqual(RateLimitWindow.percentText(42.6), "43%")

        // 老版本存下的快照没有 pendingText：照常解码成 nil
        let old = Data(#"{"kind":"session","label":"5h","usedPercent":12}"#.utf8)
        let decoded = try JSONDecoder().decode(RateLimitWindow.self, from: old)
        XCTAssertNil(decoded.pendingText)
        XCTAssertFalse(decoded.isPending)
        let withPending = RateLimitWindow(kind: "doubao-1", label: "当前时段", usedPercent: 0, pendingText: "开始使用后计时")
        let roundTrip = try JSONDecoder().decode(RateLimitWindow.self, from: JSONEncoder().encode(withPending))
        XCTAssertEqual(roundTrip.pendingText, "开始使用后计时")
    }

    // MARK: - 详情页收尾

    func testDetailDecorationGivesDateAndModelSubtitles() async throws {
        let store = DoubaoWorkStore(fileURL: directory.appendingPathComponent("d.json"), dataDirectory: directory)
        await store.seedForTesting([
            item("1", title: "查资料", model: "Auto", at: 1_790_150_000, credits: 0.2),
            item("2", title: "查资料", model: "豆包 2.1 Turbo", at: 1_790_150_600, credits: 1.5),
        ])
        let ledger = FileMtimeCache()
        _ = try await DoubaoWorkProvider(store: store, ledger: ledger).fetchDailyRecords()
        let details = await ledger.details(forProvider: "doubao-work")
        let now = Date(timeIntervalSince1970: 1_790_200_000)
        let base = LedgerDetailAggregator.aggregate(providerId: "doubao-work", details: details, window: .all, now: now)
        let synced = Date(timeIntervalSince1970: 1_790_199_000)
        let d = DoubaoWorkDetail.decorated(base, details: details, window: .all, weekStartMonday: true, now: now,
                                           costAvailable: false, costSyncedAt: synced)
        let day = DateFormatter()
        day.locale = Locale(identifier: "zh_CN")
        day.dateFormat = "MM-dd"
        XCTAssertEqual(d.sessions.map(\.subtitle),
                       ["\(day.string(from: Date(timeIntervalSince1970: 1_790_150_600))) · 豆包 2.1 Turbo / Auto"],
                       "日期 = 最后一次消耗；模型按积分多少排")
        XCTAssertFalse(d.costAvailable)
        XCTAssertEqual(d.costSyncedAt, synced)
        XCTAssertEqual(d.cost, 1.7, accuracy: 1e-9)
    }

    // MARK: - cookie

    func testCookieHeaderDecryptsStripsHostHashAndSkipsForeignOrExpired() throws {
        let key = Data((0..<16).map { UInt8($0 * 5 + 1) })
        let db = directory.appendingPathComponent("Cookies")
        let future: Int64 = Int64((Date().timeIntervalSince1970 + 11_644_473_600 + 86_400) * 1_000_000)
        let past: Int64 = Int64((Date().timeIntervalSince1970 + 11_644_473_600 - 86_400) * 1_000_000)
        try makeCookieDB(at: db, rows: [
            // Chromium ≥130：明文前 32 字节是 SHA256(host_key)
            (".doubao.com", "sessionid", try encrypt(Data(SHA256.hash(data: Data(".doubao.com".utf8))) + data("S1"), key: key), future),
            // 老版本：没有哈希前缀
            ("www.doubao.com", "msToken", try encrypt(data("M1"), key: key), 0),
            // 同名：域 cookie（带点）优先
            ("www.doubao.com", "uid_tt", try encrypt(data("host-only"), key: key), future),
            (".doubao.com", "uid_tt", try encrypt(Data(SHA256.hash(data: Data(".doubao.com".utf8))) + data("domain"), key: key), future),
            // 已过期 / 其它子域（CDN）的不带
            (".doubao.com", "old", try encrypt(data("x"), key: key), past),
            ("lf-flow-web-cdn.doubao.com", "cdn", try encrypt(data("y"), key: key), future),
        ])
        let rows = ChromiumCookieStore.rows(in: db, hostLike: "%doubao.com")
        XCTAssertEqual(rows.count, 6)
        let header = DoubaoWorkStore.cookieHeader(rows: rows, key: key)
        let pairs = Set(header.components(separatedBy: "; "))
        XCTAssertEqual(pairs, ["sessionid=S1", "msToken=M1", "uid_tt=domain"])
        XCTAssertEqual(ChromiumCookieStore.rows(in: db, hostLike: "%doubao.com", name: "sessionid").count, 1)
    }

    private func encrypt(_ plain: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        let capacity = out.count
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
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + out.prefix(moved)
    }

    private func makeCookieDB(at url: URL, rows: [(String, String, Data, Int64)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER);
            CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','24');
            """, nil, nil, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (host, name, blob, expires) in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?1, ?2, '', ?3, ?4)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, host, -1, transient)
            sqlite3_bind_text(stmt, 2, name, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_bind_int64(stmt, 4, expires)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }
}
