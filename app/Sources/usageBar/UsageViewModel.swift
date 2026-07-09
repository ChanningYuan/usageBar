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

    // MARK: - drill-in 详情（懒加载，独立于主刷新快路径）

    /// 非 nil = 正在看某 provider（claude-sub / claude-api）的详情页；nil = 列表态
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

        // 1) 并发扫盘:解析新增/变更文件 → 存入 FileMtimeCache(副作用)。返回值仅 DEBUG 计时用。
        await withTaskGroup(of: Void.self) { group in
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
                }
            }
        }

        // 只有最新 generation 才 commit
        guard myGen == refreshGen else {
            log("discarded (stale)")
            return
        }

        // 2) 第一阶段聚合(本地数据,秒回)。Cursor 此刻读的是已有 mirror(可能是旧值)。
        await commitAggregation(providerIds: providerIds, log: log)
        // 首次运行智能默认：只保留「用过」的 provider（有用量 ∪ 有本地数据），其余自动隐藏（仅一次）。
        // Qoder CLI / Work 特例：装了但没开 QODER_EXPOSE_TOKEN_USAGE 时 transcript 零 token，仍按会话文件算
        // 「用过」，否则会被自动隐藏 → 连「去开启」横幅都看不到（见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md）。
        // （IDE 不受 gate，用过必有 token>0，本就进 keep，无需特判。）
        var keep = Set(allStats.filter { $0.token > 0 }.map { $0.provider })
        if QoderUsageEnvGate.isQoderCliPresent() { keep.insert("qoder-cli") }
        if QoderUsageEnvGate.isQoderWorkPresent() { keep.insert("qoder-work") }
        ProviderVisibilitySettings.shared.autoConfigureFirstRunIfNeeded(providerIdsToKeep: keep)
        // 每次刷新顺带扫一遍 Qoder 的 env 开关状态（CLI/Work 共用），驱动弹层/设置页横幅。
        QoderUsageStatus.shared.refresh()
        self.lastRefreshAt = Date()
        self.isRefreshing = false
        log("local done, total \(allStats.count) records")
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
        self.stats = computed.filter { $0.time == window.id }
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
        let expandable: Set<String> = ["claude-sub", "claude-api", "codex"]
        let providers = Set(
            allStats
                .filter { $0.time == TimeWindow.today.id && visible.contains($0.provider) && $0.token > 0 }
                .map { $0.provider }
        )
        guard providers.count == 1, let only = providers.first, expandable.contains(only) else { return nil }
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
        // 按 provider 分发到对应扫描器：Codex 走 CodexDetailScanner（累计差分口径），其余走 Claude。
        let d: ProviderDetail
        if providerId == "codex" {
            d = await CodexDetailScanner.shared.detail(
                providerId: providerId, window: win, weekStartMonday: weekStartMonday)
        } else if providerId == "opencode" {
            d = await OpenCodeDetailScanner.shared.detail(
                window: win, weekStartMonday: weekStartMonday)
        } else {
            d = await ClaudeDetailScanner.shared.detail(
                providerId: providerId, window: win, weekStartMonday: weekStartMonday)
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
