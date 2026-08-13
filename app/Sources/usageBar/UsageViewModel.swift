import Foundation
import SwiftUI
import usageBarCore
import usageBarProviders

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var window: TimeWindow = .today
    /// 当前窗口的 5 条 StatRecord（UI 直接用）
    @Published var stats: [StatRecord] = []
    @Published var isRefreshing: Bool = false
    @Published var lastRefreshAt: Date?
    @Published var justRefreshed: Bool = false
    /// 首扫（缓存为空的第一次全量索引）进行中。驱动弹层 footer 的「首次索引历史数据…」提示（0709 R2）。
    @Published var isFirstScan: Bool = false
    /// 扫描进度（done/total 数据源）。仅刷新进行中非 nil。
    @Published var scanProgress: (done: Int, total: Int)?

    // MARK: - drill-in 详情（懒加载，独立于主刷新快路径）

    /// 非 nil = 正在看某个可展开 provider 的详情页；nil = 列表态
    @Published var detailProviderId: String? = nil
    /// 已加载的详情（nil 且 detailProviderId != nil = 加载中）
    @Published var detail: ProviderDetail? = nil

    /// 全量缓存：4 窗口 × 5 provider = 20 条
    private var allStats: [StatRecord] = []

    /// generation 计数器，旧请求结果被丢弃
    private var refreshGen: Int = 0

    private var justRefreshedTask: Task<Void, Never>?

    var grandTotalToken: Int {
        stats.reduce(0) { $0 + $1.token }
    }

    /// 可见 provider 的合计(用户在 Settings 关闭的不计入,菜单栏 title 用这个)
    var visibleGrandTotalToken: Int {
        let visible = Set(ProviderVisibilitySettings.shared.visibleProviderIds())
        return stats
            .filter { visible.contains($0.provider) }
            .reduce(0) { $0 + $1.token }
    }

    /// 指定周期的可见合计（不看当前 window）。菜单栏 title 用它固定读「今日」。
    func visibleTotal(for window: TimeWindow) -> Int {
        let visible = Set(ProviderVisibilitySettings.shared.visibleProviderIds())
        return allStats
            .filter { $0.time == window.id && visible.contains($0.provider) }
            .reduce(0) { $0 + $1.token }
    }

    /// 当前窗口内最大 token 数（条形归一化）
    var maxToken: Int {
        stats.map { $0.token }.max() ?? 0
    }

    /// 触发一次"所有 provider 并发扫盘刷新缓存 + 按缓存全量(持久账本)聚合"。
    ///
    /// **持久账本语义**(2026-05-29 拍板):聚合数据源是 `FileMtimeCache.allEntries()`(按 path
    /// 的全量缓存),而非各 provider 当前扫到的现存文件。这样会话文件被删/轮转后,其历史条目仍
    /// 留在缓存里继续计入「累计/近 30 天」——消耗过的 token 不丢。providers 的 fetchDailyRecords
    /// 在这里只为**副作用**:把新增/变更文件解析进缓存(命中 mtime/size 则跳过)。
    ///
    /// ⚠️ 代价:`file-cache.json` 升为承载历史真相的关键文件,损坏/删除会丢失已删源文件的历史
    /// (现存文件仍可重扫恢复)。后续建议加定期备份。
    func refresh() async {
        refreshGen += 1
        let myGen = refreshGen
        // 调试日志只在 DEBUG 构建保留;release .app(swift build -c release)编译掉,避免污染系统日志
        let log: (String) -> Void = { msg in
            #if DEBUG
            fputs("[\(Date())] [refresh gen=\(myGen)] \(msg)\n", stderr)
            #endif
        }
        log("called")
        isRefreshing = true

        let providers = ProviderRegistry.all
        let providerIds = providers.map { $0.id }

        // 首扫判定：缓存为空 = 首次全量索引（0709 R2）。驱动「首次索引历史数据…」提示与渐进期 0 值行过滤。
        isFirstScan = await FileMtimeCache.shared.count() == 0
        scanProgress = (0, providers.count)

        // 1) 并发扫盘:解析新增/变更文件 → 存入 FileMtimeCache(副作用)。
        //    渐进提交（0709 R1）：每个 provider 完成即聚合上屏，不等最慢的那个——
        //    否则 12 个源 1 秒扫完、最大的源扫 15 秒,用户就看 15 秒的 0。
        await withTaskGroup(of: String.self) { group in
            for p in providers {
                group.addTask {
                    #if DEBUG
                    let t0 = Date()
                    let name = p.displayName
                    let recs = (try? await p.fetchDailyRecords()) ?? []
                    let dt = Date().timeIntervalSince(t0)
                    fputs("[\(Date())] [refresh gen=\(myGen)]   '\(name)' done in \(String(format: "%.2fs", dt)), records=\(recs.count)\n", stderr)
                    #else
                    _ = try? await p.fetchDailyRecords()
                    #endif
                    return p.id
                }
            }
            var done = 0
            for await pid in group {
                done += 1
                // 旧代不再 commit（但仍要把 group 消费完，别悬挂任务）
                guard myGen == refreshGen else { continue }
                scanProgress = (done, providers.count)
                await commitAggregation(providerIds: providerIds, log: log)
                log("progressive commit after '\(pid)' (\(done)/\(providers.count))")
                // 周期性缓存落盘（0709 §9）：只有正常退出才存的话，首扫 20 分钟中途强退 = 全部白扫。
                // 节流 + 后台 fire-and-forget，不拖慢渐进上屏。
                Task.detached(priority: .utility) { await FileMtimeCache.shared.saveToDiskThrottled() }
            }
        }

        // 只有最新 generation 才走收尾（渐进 commit 已在循环内做过 gen 守卫）
        guard myGen == refreshGen else {
            log("discarded (stale)")
            return
        }
        scanProgress = nil
        isFirstScan = false

        // 2) 收尾聚合(保证终态完整)。Cursor 此刻读的是已有 mirror(可能是旧值)。
        await commitAggregation(providerIds: providerIds, log: log)
        // 首次运行智能默认：只保留「用过」的 provider（有用量 ∪ 有本地数据），其余自动隐藏（仅一次）。
        // Qoder CLI / 千问办公特例：没开各自 EXPOSE_TOKEN_USAGE gate 时日志零 token，仍按会话文件算
        // 「用过」，否则会被自动隐藏 → 连「去开启」横幅都看不到（见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md）。
        // （IDE 不受 gate，用过必有 token>0，本就进 keep，无需特判。）
        var keep = Set(allStats.filter { $0.token > 0 }.map { $0.provider })
        if QoderUsageEnvGate.isQoderCliPresent() { keep.insert("qoder-cli") }
        if QoderUsageEnvGate.isQwenWorkPresent() { keep.insert("qwen-work") }
        ProviderVisibilitySettings.shared.autoConfigureFirstRunIfNeeded(providerIdsToKeep: keep)
        // 每次刷新顺带扫一遍 Qoder 的 env 开关状态，驱动弹层/设置页横幅。
        QoderUsageStatus.shared.refresh()
        // 远程价目表每日条件拉取（内部 24h 节流 + ETag 304，非到期零开销；详见 RemotePricing）
        Task.detached(priority: .utility) { await RemotePricing.shared.refreshIfNeeded() }
        self.lastRefreshAt = Date()
        self.isRefreshing = false
        log("local done, total \(allStats.count) records")

        // 额度采集：跟随本次刷新（自动 10 分钟 / ⌘R 都会走到这），与 token 聚合并发、互不阻塞。
        Task { await RateLimitCoordinator.refreshEnabled() }
        triggerJustRefreshedFlash()

        // 3) 第二阶段:Cursor 联网拉取(慢,~1.5s),不阻塞上面的 UI commit。
        //    拉到新数据 → 让 Cursor 重新进 FileMtimeCache(mirror mtime 变了触发 cache miss)→ 二次聚合刷新那一行。
        //    见 docs/0510-Cursor接入/cursor-refresh-latency.md 方案 B(渐进式刷新)。
        await refreshCursorInBackground(myGen: myGen, providerIds: providerIds, log: log)
    }

    /// 从 FileMtimeCache 全量聚合并 commit 到 UI(持久账本语义)。
    private func commitAggregation(providerIds: [String], log: (String) -> Void) async {
        let allDaily = await FileMtimeCache.shared.allEntries().flatMap { $0.records }
        let computed = DailyAggregator.aggregate(
            allDailyRecords: allDaily,
            providerIds: providerIds,
            weekStartMonday: TabSettings.shared.weekStartMonday,
            customRange: TabSettings.shared.customRange
        )
        self.allStats = computed
        // 首扫渐进期只显示已扫出数值的行（0709 §4）：首装 autoConfigure 要等全部扫完才跑，
        // 不过滤的话 12 行 0 值先闪现、随后被自动隐藏收走，视觉上一片跳动。
        if isFirstScan {
            self.stats = computed.filter { $0.time == window.id && $0.token > 0 }
        } else {
            self.stats = computed.filter { $0.time == window.id }
        }
    }

    /// 仅从内存缓存重新聚合（不扫盘）。用于 tab 配置变化（周起始/自定义区间）后即时刷新，秒回。
    func recomputeFromCache() async {
        await commitAggregation(providerIds: ProviderRegistry.all.map { $0.id }, log: { _ in })
    }

    /// 方案 B 第二阶段:Cursor 后台联网拉取,完成后二次聚合(仅当本次刷新仍是最新 generation)。
    private func refreshCursorInBackground(myGen: Int, providerIds: [String], log: @escaping (String) -> Void) async {
        guard let cursor = ProviderRegistry.all.first(where: { $0.id == "cursor" }) as? CursorProvider else { return }
        let changed = await cursor.refreshFromNetwork()
        guard myGen == refreshGen else { log("cursor bg discarded (stale)"); return }
        guard changed else { log("cursor bg: no new data"); return }
        // mirror 已更新 → 让 Cursor 重新解析进缓存 → 二次聚合
        _ = try? await cursor.fetchDailyRecords()
        guard myGen == refreshGen else { return }
        await commitAggregation(providerIds: providerIds, log: log)
        log("cursor bg: updated")
    }

    /// 切窗口：纯走缓存，0ms
    func changeWindow(_ newWindow: TimeWindow) {
        guard newWindow != window else { return }
        window = newWindow
        self.stats = allStats.filter { $0.time == newWindow.id }
    }

    // MARK: - drill-in 详情

    /// 进入某 provider 详情页：切路由 + 异步懒加载明细（当前窗口）。
    func openDetail(_ providerId: String) {
        detailProviderId = providerId
        detail = nil
        Task { await loadDetail(providerId: providerId) }
    }

    /// 今日「仅有一个可展开 provider 有用量」时返回它的 id（打开弹层直接进今日详情用）；否则 nil。
    /// 判定：全量缓存里今日记录 ∩ 可见 ∩ token>0，恰好一个，且属于可展开集合。
    func soleTodayDetailProvider() -> String? {
        let visible = Set(ProviderVisibilitySettings.shared.visibleProviderIds())
        let providers = Set(
            allStats
                .filter { $0.time == TimeWindow.today.id && visible.contains($0.provider) && $0.token > 0 }
                .map { $0.provider }
        )
        // 门禁走声明表（v0.3.22）。此前这里还硬编码着 `["claude-code", "codex"]` ——
        // 比 UsageView 那处白名单还旧（OpenCode 早就能 drill-in 了却没加进来），
        // 正是「同一个门禁散在多处、加 provider 必漏」的活证据。
        guard providers.count == 1, let only = providers.first,
              ProviderDetailRegistry.isDrillable(only) else { return nil }
        return only
    }

    /// 返回列表态。
    func closeDetail() {
        detailProviderId = nil
        detail = nil
    }

    /// 详情页内切周期：切窗口（`window` 是同一个 @Published，返回列表时列表 tab 随之跟随）
    /// + 按新周期重载明细（`detail=nil` 先显示「统计中…」）。
    func changeWindowInDetail(_ newWindow: TimeWindow) {
        guard let pid = detailProviderId, newWindow != window else { return }
        changeWindow(newWindow)   // 更新 window + 列表 stats
        detail = nil
        Task { await loadDetail(providerId: pid) }
    }

    private func loadDetail(providerId: String) async {
        let win = window
        let weekStartMonday = TabSettings.shared.weekStartMonday
        // 扫描器由 provider 声明表给（`ProviderDetailSpec.swift`），不再手写 if/else 分派链。
        // ⚠️ `.claudeTranscript` 必须把根目录传下去 —— 重构前 ClaudeDetailScanner 的路径是写死的
        //    `~/.claude/projects`、完全无视 providerId，Cowork 一旦放开 drill-in 就会显示 Claude Code
        //    的数据（白名单恰好挡住、bug 尚未暴露）。
        guard let spec = ProviderDetailRegistry.spec(for: providerId) else { return }

        // ── v0.3.33：**所有 provider 一律先读持久明细账本** ────────────────────
        // 主扫盘已把「会话 / 模型 / 5 列拆分」落进账本，详情页不再实时重扫源日志。
        // 源被工具清理、被权限挡住（issue #8 的 Operation not permitted）、SQLite 被锁，
        // 都不影响展开——这正是本版要根治的「列表有量 / 详情空」。
        //
        // 只有账本里**这个 provider 一条明细都没有**时才回落到实时扫源：
        //   - 刚升级、首扫还没跑完；
        //   - 该 provider 本轮扫盘失败（源目录不存在等）。
        // 回落是降级路径，不是常态；两条路的聚合口径逐字一致（见 LedgerDetailAggregator）。
        //
        // ⚠️ 千问办公例外一步：它的**积分**来自联网账单，不在账本里（账单行金额会原地增长，
        // 存进账本就是陈旧值）。所以进详情页时照旧刷新账单，token 明细才走账本。
        if providerId == "qwen-work", RateLimitSettings.shared.isEnabled("qwen-work") {
            _ = await QwenWorkBillingStore.shared.refresh()
        }

        var d: ProviderDetail
        if await FileMtimeCache.shared.hasDetails(forProvider: providerId) {
            d = LedgerDetailAggregator.aggregate(
                providerId: providerId,
                details: await FileMtimeCache.shared.details(forProvider: providerId),
                window: win, weekStartMonday: weekStartMonday,
                costUnavailable: spec.costUnit == .unavailable)
            // 千问办公的积分不在账本里 → 用实时链路的金额覆盖账本算出来的（后者恒 0）。
            if providerId == "qwen-work" {
                let live = await QwenWorkDetailScanner.shared.detail(
                    window: win, weekStartMonday: weekStartMonday)
                d = ProviderDetail(providerId: d.providerId, windowId: d.windowId,
                                   tokens: d.tokens, cost: live.cost,
                                   costAvailable: live.costAvailable,
                                   sources: d.sources, models: d.models, sessions: live.sessions)
            }
        } else {
            switch spec.scanner {
            case .claudeTranscript(let src):
                d = await ClaudeDetailScanner.shared.detail(
                    providerId: providerId, root: src.root,
                    includeHidden: src.includeHidden,
                    requirePath: src.requirePath, excludePath: src.excludePath,
                    window: win, weekStartMonday: weekStartMonday)
            case .codexRollout(let root, let requirePath):
                d = await CodexDetailScanner.shared.detail(
                    providerId: providerId, root: root, requirePath: requirePath,
                    window: win, weekStartMonday: weekStartMonday)
            case .openCode:
                d = await OpenCodeDetailScanner.shared.detail(
                    window: win, weekStartMonday: weekStartMonday)
            case .cursor:
                d = await CursorDetailScanner.shared.detail(
                    window: win, weekStartMonday: weekStartMonday)
            case .workBuddy:
                d = await WorkBuddyDetailScanner.shared.detail(
                    window: win, weekStartMonday: weekStartMonday)
            case .qoderIde:
                d = await QoderIdeDetailScanner.shared.detail(
                    window: win, weekStartMonday: weekStartMonday)
            case .qwenWork:
                d = await QwenWorkDetailScanner.shared.detail(
                    window: win, weekStartMonday: weekStartMonday)
            }
        }
        // 仅当用户仍停在同一 provider 详情页才 commit（防止快速来回切）
        guard detailProviderId == providerId, win == window else { return }
        detail = d
    }

    private func triggerJustRefreshedFlash() {
        justRefreshedTask?.cancel()
        justRefreshed = true
        justRefreshedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.justRefreshed = false
            }
        }
    }
}
