import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// v0.3.33 账本升级的回归锁：详情页改读**持久明细账本**（issue #8 根治）。
///
/// 这几条锁住的都是当初出 bug 的点，改动详情数据链路前先确认它们还绿：
/// 源文件没了明细还在 / 列表与详情同源不打架 / 跨源去重不翻倍。
final class LedgerDetailTests: XCTestCase {

    private func detail(_ p: String, _ date: String, _ session: String,
                        _ model: String, input: Int, output: Int, cacheRead: Int = 0,
                        title: String = "", at: String = "2026-08-14T10:00:00+08:00") -> FileDetailRecord {
        FileDetailRecord(
            provider: p, date: date, sessionId: session, title: title, model: model,
            lastActivity: ISODateParser.parse(at) ?? Date(),
            tokens: TokenBreakdown(input: input, output: output, cacheRead: cacheRead))
    }

    /// 源日志已被工具清理（文件不存在）时，详情页仍能从账本展开完整明细。
    /// —— 这正是 issue #8 的核心症状：以前列表有数、详情空。
    func testDetailSurvivesMissingSourceFile() async {
        let cache = FileMtimeCache()
        let ghost = "/nonexistent/gone-\(UUID().uuidString).jsonl"
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost))

        await cache.store(FileCacheEntry(
            filePath: ghost, mtime: Date(), size: 1,
            records: [FileDailyRecord(provider: "qoder-cli", date: "2026-08-14",
                                      token: 300, cachedToken: 100)],
            details: [detail("qoder-cli", "2026-08-14", "s1", "cmodel",
                             input: 150, output: 50, cacheRead: 100, title: "修 appcast")]))

        let details = await cache.details(forProvider: "qoder-cli")
        let d = LedgerDetailAggregator.aggregate(
            providerId: "qoder-cli", details: details, window: .all, costUnavailable: true)

        XCTAssertEqual(d.tokens.total, 300, "源文件没了，明细总量仍在")
        XCTAssertEqual(d.models.count, 1)
        XCTAssertEqual(d.sessions.count, 1)
        XCTAssertEqual(d.sessions.first?.title, "修 appcast", "会话标题也存进了账本")
    }

    /// **最重要的不变量**：列表总量 = Hero = 分模型合计 = 分会话合计。
    /// 四处对不上正是 issue #8 被报上来的原因。
    func testListEqualsHeroEqualsModelsEqualsSessions() async {
        let cache = FileMtimeCache()
        let ds = [
            detail("claude-code", "2026-08-14", "s1", "claude-opus-4-7", input: 100, output: 20, cacheRead: 30),
            detail("claude-code", "2026-08-14", "s1", "claude-haiku-4-5", input: 10, output: 5),
            detail("claude-code", "2026-08-14", "s2", "claude-opus-4-7", input: 50, output: 10, cacheRead: 5),
        ]
        let listTotal = ds.reduce(0) { $0 + $1.tokens.total }
        await cache.store(FileCacheEntry(
            filePath: "/tmp/x-\(UUID().uuidString).jsonl", mtime: Date(), size: 1,
            records: [FileDailyRecord(provider: "claude-code", date: "2026-08-14",
                                      token: listTotal, cachedToken: 35)],
            details: ds))

        let allDaily = await cache.allEntries().flatMap { $0.records }
        let listed = DailyAggregator.aggregate(allDailyRecords: allDaily,
                                               providerIds: ["claude-code"])
            .first { $0.provider == "claude-code" && $0.time == "all" }?.token

        let d = LedgerDetailAggregator.aggregate(
            providerId: "claude-code",
            details: await cache.details(forProvider: "claude-code"), window: .all)

        XCTAssertEqual(listed, d.tokens.total, "主列表 == 详情 Hero")
        XCTAssertEqual(d.models.reduce(0) { $0 + $1.tokens.total }, d.tokens.total, "分模型合计 == Hero")
        XCTAssertEqual(d.sessions.reduce(0) { $0 + $1.tokens.total }, d.tokens.total, "分会话合计 == Hero")
        XCTAssertEqual(d.models.count, 2)
        XCTAssertEqual(d.sessions.count, 2)
    }

    /// 明细按 provider 隔离：一份账本里多个 provider 的条目不能互相串。
    func testDetailsAreScopedByProvider() async {
        let cache = FileMtimeCache()
        await cache.store(FileCacheEntry(
            filePath: "/tmp/y-\(UUID().uuidString).jsonl", mtime: Date(), size: 1,
            records: [],
            details: [detail("claude-code", "2026-08-14", "a", "m1", input: 100, output: 0),
                      detail("qoder-cli", "2026-08-14", "b", "m2", input: 7, output: 0)]))

        let claude = LedgerDetailAggregator.aggregate(
            providerId: "claude-code",
            details: await cache.details(forProvider: "claude-code"), window: .all)
        XCTAssertEqual(claude.tokens.total, 100, "不该把 qoder-cli 的量算进来")
        let hasQoder = await cache.hasDetails(forProvider: "qoder-cli")
        let hasCodex = await cache.hasDetails(forProvider: "codex")
        XCTAssertTrue(hasQoder)
        XCTAssertFalse(hasCodex)
    }

    /// 「无价目」provider（模型名被厂商打码）不查价目表，cost 恒 0。
    /// 防止撞名撞出一个有模有样的假金额（见 ModelPricing.genericAliases 的警告）。
    func testCostUnavailableProviderReportsZeroCost() async {
        let ds = [detail("qoder-cli", "2026-08-14", "s", "cmodel", input: 1_000_000, output: 500_000)]
        let d = LedgerDetailAggregator.aggregate(
            providerId: "qoder-cli", details: ds, window: .all, costUnavailable: true)
        XCTAssertEqual(d.cost, 0, accuracy: 0.0001)
    }

    /// **fork 文件的用量必须进账本**（v0.3.33 修的老 bug）。
    ///
    /// 老行为：`CodexProvider` 对 fork 文件一律不写缓存（怕 baseline 失效）。但主列表是从账本
    /// 聚合的 —— 不写 = fork 会话的用量在主列表里根本不存在。本机实测因此丢了 87 万 token
    /// （列表 18.0M vs 详情 18.9M）。现在 fork 用 `路径#fork` 合成 key 覆盖写，
    /// 永不被 mtime 命中、每轮以最新 baseline 重算。
    ///
    /// 这条锁的是「合成 key 不会被 lookup 命中」这个前提 —— 一旦哪天有人把它改回真实路径，
    /// fork 就会命中旧缓存、baseline 不再重算，回到虚高老路。
    func testForkLedgerKeyNeverHitsMtimeLookup() async {
        let cache = FileMtimeCache()
        let realPath = "/tmp/rollout-fork-\(UUID().uuidString).jsonl"
        let mtime = Date()

        await cache.store(FileCacheEntry(
            filePath: realPath + "#fork", mtime: mtime, size: 1,
            records: [FileDailyRecord(provider: "codex", date: "2026-08-11", token: 869_765)]))

        // 用真实路径 + 同样的 mtime/size 去查 —— 必须 miss（key 不同）
        let hit = await cache.lookup(filePath: realPath, mtime: mtime, size: 1)
        XCTAssertNil(hit, "fork 条目不能被真实路径的 mtime 查询命中，否则 baseline 不会重算")

        // 但它必须计入账本聚合（这才是修复的意义）
        let allDaily = await cache.allEntries().flatMap { $0.records }
        let total = DailyAggregator.aggregate(allDailyRecords: allDaily, providerIds: ["codex"])
            .first { $0.provider == "codex" && $0.time == "all" }?.token
        XCTAssertEqual(total, 869_765, "fork 会话的用量必须出现在主列表里")
    }

    /// 会话标题取「活动时间最新」那条——会话被 /rename 后以最后一次为准。
    func testSessionTitleTakesLatest() async {
        let ds = [
            detail("claude-code", "2026-08-13", "s1", "m", input: 10, output: 0,
                   title: "旧名字", at: "2026-08-13T10:00:00+08:00"),
            detail("claude-code", "2026-08-14", "s1", "m", input: 10, output: 0,
                   title: "改过的新名字", at: "2026-08-14T10:00:00+08:00"),
        ]
        let d = LedgerDetailAggregator.aggregate(
            providerId: "claude-code", details: ds, window: .all)
        XCTAssertEqual(d.sessions.first?.title, "改过的新名字")
    }
}
