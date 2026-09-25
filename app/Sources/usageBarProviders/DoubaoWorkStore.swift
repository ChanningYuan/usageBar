import Foundation
import Security
import usageBarCore

/// 豆包工作同步失败的原因（设置页状态标签、详情页 Hero 提示、主列表灰字都按它分档说）。
public enum DoubaoWorkSyncError: String, Codable, Sendable, Equatable {
    /// 本机没有豆包工作（或它的 cookie 库 / 钥匙串条目不存在）
    case notInstalled
    /// 钥匙串授权被拒（6 小时内不再自动碰钥匙串，免得反复弹框）
    case authDenied
    /// 豆包工作的登录已过期（接口回业务码 710012001）——打开豆包工作重新登录后自动恢复
    case loggedOut
    /// 网络 / 服务端暂时异常——保留上次数据
    case network
}

/// 一次同步后的状态快照（给额度药丸、详情页、设置页用）。
public struct DoubaoWorkSyncStatus: Sendable, Equatable {
    public let quota: DoubaoWorkQuota?
    /// 额度窗口最后一次拿到的时刻（药丸据此判陈旧；明细失败不影响它）
    public let quotaFetchedAt: Date?
    /// 最后一次**完整成功**（额度 + 明细都拿到）的时刻。失败时界面照样显示缓存，但标「截至 HH:mm」。
    public let lastSyncAt: Date?
    public let error: DoubaoWorkSyncError?
    /// 本次有没有新增 / 变化的消耗记录（调用方据此决定要不要把镜像重新写进账本并重算）
    public let itemsChanged: Bool
}

/// 钥匙串授权被拒后的退避（6 小时内不再自动碰钥匙串；照千问办公 Chrome 授权的规则）。
public enum DoubaoWorkKeychainBackoff {
    static let key = "usagebar.doubaoWorkKeychainDeniedUntil.v1"
    public static let duration: TimeInterval = 6 * 3600

    public static func deniedUntil(now: Date = Date()) -> Date? {
        guard let until = UserDefaults.standard.object(forKey: key) as? Date, until > now else { return nil }
        return until
    }

    public static func noteDenied(now: Date = Date()) {
        UserDefaults.standard.set(now.addingTimeInterval(duration), forKey: key)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 豆包工作的联网同步 + 本地明细镜像。
///
/// ## 为什么要有「镜像」，而不是直接写账本
///
/// 服务端明细只展示近 30 天。镜像（`doubao-work.json`）是这些消耗在本机的**唯一持久来源**：
/// provider 每轮从镜像写账本（`DoubaoWorkProvider`）。账本哪天因 schema 升级整份作废重建
/// （`PersistedCache.currentSchemaVersion`），也能从镜像原样恢复——服务端那头早就删了。
///
/// ## 同一笔会「原地变大」
///
/// 任务跑的过程中积分是逐步累加的（2026-09-24 实抓：一次工具任务推送依次是 <0.01 → 0.02 → … → 0.47 → 0.54，
/// 明细最终入账 0.54）。所以按 `itemId` **覆盖**，不是追加；每轮刷新都会重拉最近 48 小时的明细把值刷成终值。
public actor DoubaoWorkStore {
    public static let shared = DoubaoWorkStore()

    public static let keychainService = "DoubaoWork Safe Storage"
    /// 增量同步往回看多远：这之前的笔都已是终值（任务跑完积分就不再变）
    static let incrementalHorizon: TimeInterval = 48 * 3600
    /// 单次最多翻几页（50 条一页）。首次同步 30 天 2000 笔远超真实用量，只是防服务端异常时死循环。
    static let maxPages = 40

    private static let cacheVersion = 1

    private struct CacheFile: Codable {
        let version: Int
        let updatedAt: Date
        let quota: DoubaoWorkQuota?
        let quotaFetchedAt: Date?
        let lastSyncAt: Date?
        /// 已完整拉过一遍 30 天明细的账号（哈希）。换号后第一次同步会重新拉满 30 天
        let fullySyncedAccounts: [String]
        let items: [DoubaoWorkUsageItem]
    }

    private let fileURL: URL
    private let dataDirectory: URL
    private var items: [String: DoubaoWorkUsageItem] = [:]
    private var quota: DoubaoWorkQuota?
    private var quotaFetchedAt: Date?
    private var lastSyncAt: Date?
    private var fullySyncedAccounts: Set<String> = []
    private var lastError: DoubaoWorkSyncError?
    /// 钥匙串派生的 AES 密钥，只放内存：每轮刷新重读 cookie，但不每轮碰钥匙串
    private var cachedKey: Data?
    private var loaded = false
    private var refreshInFlight = false
    private var lastRefreshAt: Date?

    public static var defaultPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("usageBar", isDirectory: true)
            .appendingPathComponent("doubao-work.json")
    }

    init(fileURL: URL = DoubaoWorkStore.defaultPath, dataDirectory: URL = DoubaoWorkEnv.dataDirectory) {
        self.fileURL = fileURL
        self.dataDirectory = dataDirectory
    }

    // MARK: 读

    public func status() -> DoubaoWorkSyncStatus {
        loadIfNeeded()
        return DoubaoWorkSyncStatus(quota: quota, quotaFetchedAt: quotaFetchedAt, lastSyncAt: lastSyncAt,
                                    error: lastError, itemsChanged: false)
    }

    /// 镜像里的全部消耗（含服务端早已删掉的 30 天前的笔），时间倒序。
    public func allItems() -> [DoubaoWorkUsageItem] {
        loadIfNeeded()
        return items.values.sorted { $0.occurredAt > $1.occurredAt }
    }

    /// 重置授权：丢掉内存里的密钥与退避。**消耗历史保留**（同千问办公：历史是用户要的本地记录）。
    public func clearAuthCache() {
        cachedKey = nil
        DoubaoWorkKeychainBackoff.clear()
    }

    // MARK: 同步

    /// 联网刷新额度与明细。任一步失败都保留旧数据，只记录失败原因。
    ///
    /// - `force`：用户主动动作（设置页开启 / 重试）——解除授权退避、跳过 30 秒节流。
    /// - 30 秒内的重复调用直接返回缓存（「打开弹层 + 主刷新」常常同时触发）。
    @discardableResult
    public func refresh(now: Date = Date(), force: Bool = false) async -> DoubaoWorkSyncStatus {
        loadIfNeeded()
        if force { DoubaoWorkKeychainBackoff.clear() }
        if !force, let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < 30 { return status() }
        // actor 在网络 await 期间可重入：显式拦住并发刷新，别一轮发两组请求
        guard !refreshInFlight else { return status() }
        refreshInFlight = true
        defer { refreshInFlight = false }
        lastRefreshAt = now

        let cookie: String
        switch acquireCookie(now: now) {
        case .failed(let error):
            lastError = error
            return status()
        case .cookie(let value):
            cookie = value
        }

        let context = DoubaoWorkAPI.RequestContext.current(dataDirectory: dataDirectory)
        switch await DoubaoWorkAPI.fetchQuota(cookie: cookie, context: context) {
        case .loggedOut:
            lastError = .loggedOut
            return status()
        case .failure:
            lastError = .network
            return status()
        case .ok(let data):
            guard let parsed = DoubaoWorkAPI.parseQuota(data) else {
                lastError = .network
                return status()
            }
            quota = parsed
            quotaFetchedAt = now
        }

        let account = quota?.accountHash ?? "unknown"
        let fullSync = !fullySyncedAccounts.contains(account)
        let result = await Self.collectTimeline(fullSync: fullSync, now: now) { cursor in
            guard case .ok(let data) = await DoubaoWorkAPI.fetchTimeline(cursor: cursor, cookie: cookie, context: context)
            else { return nil }
            return DoubaoWorkAPI.parseTimeline(data)
        }
        let changed = merge(result.items)
        if result.complete {
            if fullSync { fullySyncedAccounts.insert(account) }
            lastSyncAt = now
            lastError = nil
        } else {
            lastError = .network
        }
        persist(updatedAt: now)
        return DoubaoWorkSyncStatus(quota: quota, quotaFetchedAt: quotaFetchedAt, lastSyncAt: lastSyncAt,
                                    error: lastError, itemsChanged: changed)
    }

    /// 翻页拉明细。
    ///
    /// - 首次（这个账号从没完整同步过）：翻到 `has_more == false`，拿满服务端的 30 天。
    /// - 之后：本页最早一行已早于 48 小时就停——再往前的笔已是终值、上一轮已经拿过。
    /// - 任一页失败 → `complete == false`，已拿到的照样合并（都是真值），只是不把这轮算作成功同步。
    static func collectTimeline(
        fullSync: Bool, now: Date, maxPages: Int = DoubaoWorkStore.maxPages,
        fetch: @Sendable (String) async -> DoubaoWorkTimelinePage?
    ) async -> (items: [DoubaoWorkUsageItem], complete: Bool) {
        var collected: [DoubaoWorkUsageItem] = []
        var cursor = ""
        for _ in 0..<maxPages {
            guard let page = await fetch(cursor) else { return (collected, false) }
            collected += page.items
            guard page.hasMore, let next = page.nextCursor, !next.isEmpty else { return (collected, true) }
            if !fullSync, let oldest = page.oldest, now.timeIntervalSince(oldest) > incrementalHorizon {
                return (collected, true)
            }
            cursor = next
        }
        return (collected, true)
    }

    /// 测试用：直接灌入明细并落盘（绕开联网）。
    func seedForTesting(_ incoming: [DoubaoWorkUsageItem], quota: DoubaoWorkQuota? = nil, now: Date = Date()) {
        loadIfNeeded()
        _ = merge(incoming)
        if let quota { self.quota = quota }
        persist(updatedAt: now)
    }

    /// 按 `itemId` 覆盖合并，返回是否有变化。服务端删掉的旧笔在镜像里原样保留。
    func merge(_ incoming: [DoubaoWorkUsageItem]) -> Bool {
        var changed = false
        for item in incoming where items[item.itemId] != item {
            items[item.itemId] = item
            changed = true
        }
        return changed
    }

    // MARK: 凭证

    private enum CookieOutcome {
        case cookie(String)
        case failed(DoubaoWorkSyncError)
    }

    /// 读豆包工作自带 Chromium 壳里 doubao.com 的 cookie，拼成 `Cookie:` 头。
    ///
    /// 密钥 = PBKDF2(钥匙串「DoubaoWork Safe Storage」)——**首次会弹一次系统授权框**（设置页引导 sheet 已预告）。
    /// 被拒 → 6 小时退避，期间不再自动弹框；用户在设置里点「重试 / 重新授权」（`force`）才会再问。
    private func acquireCookie(now: Date) -> CookieOutcome {
        let database = dataDirectory.appendingPathComponent("Default/Cookies")
        guard FileManager.default.fileExists(atPath: database.path) else { return .failed(.notInstalled) }
        if cachedKey == nil {
            if DoubaoWorkKeychainBackoff.deniedUntil(now: now) != nil { return .failed(.authDenied) }
            var status: OSStatus = errSecSuccess
            guard let key = QoderRateLimitReader.deriveKey(service: Self.keychainService, status: &status) else {
                if status == errSecItemNotFound { return .failed(.notInstalled) }
                // 用户点了「拒绝」才退避；锁屏等「此刻不能弹框」（errSecInteractionNotAllowed）只是这轮拿不到
                if status == errSecUserCanceled || status == errSecAuthFailed {
                    DoubaoWorkKeychainBackoff.noteDenied(now: now)
                    return .failed(.authDenied)
                }
                return .failed(.network)
            }
            cachedKey = key
        }
        guard let key = cachedKey else { return .failed(.authDenied) }
        let header = Self.cookieHeader(
            rows: ChromiumCookieStore.rows(in: database, hostLike: "%doubao.com"), key: key, now: now)
        // 一条能用的 cookie 都没有 = 豆包工作没登录
        return header.isEmpty ? .failed(.loggedOut) : .cookie(header)
    }

    /// 只要对 `www.doubao.com` 生效的 cookie（`doubao.com` / `.doubao.com` / `www.doubao.com` / `.www.doubao.com`），
    /// 跳过已过期的；同名时**域 cookie（带点）优先**——2026-09-24 探针就是这么拼的、实测可用。
    static func cookieHeader(rows: [ChromiumCookieStore.Row], key: Data, now: Date = Date()) -> String {
        let applicable: Set<String> = ["doubao.com", ".doubao.com", "www.doubao.com", ".www.doubao.com"]
        var values: [String: (value: String, domainWide: Bool)] = [:]
        var order: [String] = []
        for row in rows where applicable.contains(row.host) && !ChromiumCookieStore.isExpired(row, now: now) {
            guard let value = ChromiumCookieStore.value(of: row, key: key), !value.isEmpty else { continue }
            let domainWide = row.host.hasPrefix(".")
            if let existing = values[row.name] {
                guard domainWide, !existing.domainWide else { continue }
            } else {
                order.append(row.name)
            }
            values[row.name] = (value, domainWide)
        }
        return order.compactMap { name in values[name].map { "\(name)=\($0.value)" } }.joined(separator: "; ")
    }

    // MARK: 持久化

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        // 毫秒精度：ISO8601 会丢掉毫秒，读回来的笔与新拉的笔永远「不相等」，每轮都被当成有变化
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let cache = try? decoder.decode(CacheFile.self, from: data),
              cache.version == Self.cacheVersion else { return }
        quota = cache.quota
        quotaFetchedAt = cache.quotaFetchedAt
        lastSyncAt = cache.lastSyncAt
        fullySyncedAccounts = Set(cache.fullySyncedAccounts)
        items = Dictionary(cache.items.map { ($0.itemId, $0) }, uniquingKeysWith: { _, latest in latest })
        // 不恢复 lastRefreshAt：启动后第一轮就该去刷新，而不是等 30 秒节流
    }

    private func persist(updatedAt: Date) {
        let file = CacheFile(
            version: Self.cacheVersion,
            updatedAt: updatedAt,
            quota: quota,
            quotaFetchedAt: quotaFetchedAt,
            lastSyncAt: lastSyncAt,
            fullySyncedAccounts: fullySyncedAccounts.sorted(),
            items: items.values.sorted { $0.occurredAt > $1.occurredAt })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 同步状态 → 额度快照（主列表两颗药丸 + 详情页额度模块，v0.3.45）。放在数据层是为了能单测。
public enum DoubaoWorkQuotaSnapshot {
    public static let providerId = "doubao-work"
    public static let sourceLabel = "豆包工作"
    /// 5 小时窗口往前 5 小时没用过时，官方界面在重置时间的位置写的就是这句
    public static let pendingText = "开始使用后计时"

    /// - 登录失效 / 授权被拒 / 没装：**药丸位换成一行提示**（窗口置空 + 错误），不拿旧数字充数（Pencil 定稿）。
    /// - 网络失败：照样给上次拿到的窗口，`capturedAt` 用那次的时间 → 超过 20 分钟自动置灰并写「更新于 x 前」。
    public static func make(_ status: DoubaoWorkSyncStatus, now: Date) -> RateLimitSnapshot {
        func failed(_ error: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: providerId, windows: [], capturedAt: now, error: error, sourceLabel: sourceLabel)
        }
        switch status.error {
        case .loggedOut?:    return failed(.credentialUnavailable)
        case .authDenied?:   return failed(.authDenied)
        case .notInstalled?: return failed(.notLoggedIn)
        case .network?, nil: break
        }
        guard let quota = status.quota else { return failed(status.error == .network ? .network : .noQuotaData) }
        let windows = quota.windows.compactMap(window)
        var headline: String?
        if let plan = quota.plan, let end = plan.endTime {
            let day = DateFormatter()
            day.locale = Locale(identifier: "zh_CN")
            day.dateFormat = "M-d"
            headline = (plan.isGift ? "赠送至 " : "有效期至 ") + day.string(from: end)
        }
        return RateLimitSnapshot(
            providerId: providerId, windows: windows, planType: quota.plan?.name,
            capturedAt: status.quotaFetchedAt ?? now,
            error: windows.isEmpty ? .noQuotaData : nil,
            sourceLabel: sourceLabel, headline: headline)
    }

    /// 一个额度窗口 → 药丸。窗口里没有已用 / 总额（aid 不对时）就不画，不编 0。
    public static func window(_ w: DoubaoWorkWindow) -> RateLimitWindow? {
        guard let usedText = w.usedText, let total = w.total, total > 0 else { return nil }
        let (label, minutes, span): (String, Int?, String) = switch w.type {
        case 1: ("当前时段", 300, "5 小时窗口")
        case 2: ("近7天", 10080, "7 天窗口")
        default: ("窗口 \(w.type)", nil, "额度窗口")
        }
        return RateLimitWindow(
            kind: "doubao-\(w.type)", label: label, windowMinutes: minutes,
            // 服务端的整数百分比小额恒 0，配 less_than_one_percent 才知道是「不到 1%」→ 0.5 显示成「<1%」
            usedPercent: w.lessThanOnePercent ? 0.5 : Double(w.usedPercent),
            resetsAt: w.endTime, used: w.used, total: total,
            // 药丸里不加千分位（同千问办公：两颗并排宽度紧），详情页小字保留服务端原串
            valueText: "已用 \(usedText)/\(compact(total))",
            notes: ["\(span) · 额度 \(w.totalText ?? compact(total)) · 已用 \(usedText)"],
            pendingText: w.endTime == nil ? pendingText : nil)
    }

    /// 紧凑数字：整数不带小数、不加千分位（"735" / "2100"）
    static func compact(_ v: Double) -> String {
        let rounded = v.rounded()
        return abs(v - rounded) < 0.005 ? String(Int(rounded)) : String(format: "%.2f", v)
    }
}
