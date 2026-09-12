import CryptoKit
import Foundation
import usageBarCore

/// 千问办公积分账单的一条记录。
///
/// `amount` 保留服务端符号：消耗为负数、奖励/充值为正数。
///
/// ⛔ **负数 ≠ 消耗**（2026-08-04 探针实证，别再改回去）：账单 `type` 有三种——
/// `对话`（真消耗）/ `过期`（当天没花完的赠送额度作废）/ `奖励`（入账）。**「过期」也是负数**。
/// 初版拿「负数即消耗」当判据，导致今日消耗虚报 100（真实 0）、历史虚增 3.6 倍
/// （过期 −988.50 混进真实消耗 −274.49）。
///
/// 判据必须是**白名单** `type == "对话"`，别用排除法排掉已知的「过期」「奖励」——
/// 厂商将来新增一种负数类型（退款 / 扣罚…）会再次被误计。
/// ⚠️ 官方「已使用」页把过期行也列在里面，所以 usageBar 的已用会**小于**官方列表，这是预期差异不是漏算。
/// 详见 `docs/0804-千问办公接入/千问办公接入-spec.md` §1c。
struct QwenWorkBillingRecord: Codable, Sendable, Equatable {
    enum Origin: String, Codable, Sendable {
        case billings
        /// `/user/billings/computer` 已被官方下线（2026-09-08 实测 410）。枚举值保留只为解码老缓存。
        case computer
    }

    /// 唯一算作「积分消耗」的账单类型。
    static let consumptionType = "对话"

    let amount: Double
    let createdAt: Date
    let source: String
    let detail: String
    let origin: Origin
    /// 服务端若将来/部分环境返回稳定 id，优先用它识别可变账单行；当前实测为空。
    let serverId: String?
    /// 服务端账单类型：`对话` / `过期` / `奖励`。老缓存没有这个字段，故 v4 整体弃用老缓存（见 `loadIfNeeded`）。
    let type: String?

    var isConsumption: Bool { type == Self.consumptionType }

    var spent: Double { isConsumption && amount < 0 ? -amount : 0 }

    /// 当前接口没有公开会话 id。以服务端 id 优先，否则用不会随 amount 变化的字段组成稳定键。
    ///
    /// ⚠️ **这个键不保证唯一**：同一秒可能有多条账单，而它们的 source / detail 也完全一样
    /// （实测 13:59:21 两条、13:08 也是同分钟多条）。去重与差分必须用 `indexedKeys` 加组内序号，
    /// 别直接拿它当字典 key——那会让同秒行互相覆盖，差分永远不收敛（见 `indexedKeys` 的注释）。
    var identityKey: String {
        if let serverId, !serverId.isEmpty {
            return "\(origin.rawValue)|id|\(serverId)"
        }
        return "\(origin.rawValue)|\(createdAt.timeIntervalSince1970)|\(source)|\(detail)"
    }
}

/// 从可变账单行差分出的积分流水。`credits` 可为负数（服务端纠正/退款），以保证累计能回到真值。
struct QwenWorkCreditLedgerEntry: Codable, Sendable, Equatable {
    let credits: Double
    let occurredAt: Date
    let recordKey: String
    let origin: QwenWorkBillingRecord.Origin
}

struct QwenWorkCreditHistory: Sendable, Equatable {
    let ledger: [QwenWorkCreditLedgerEntry]
    /// true = 本进程内已经用**当前有效的网页令牌**成功拉过一次账单。
    ///
    /// ⚠️ v0.3.38 之前「磁盘上有缓存」也算 available——于是网页令牌失效后，详情页拿 8/20 的旧账本
    /// 当「已同步」显示 `0.0000 积分`，看起来像真数（spec §2.2）。现在只认本进程的成功同步。
    let isAvailable: Bool
    /// 最后一次成功同步账单的时刻（含磁盘缓存里的）。不可用时 UI 照样显示缓存，但标「截至 HH:mm」。
    let lastSyncAt: Date?
}

// MARK: - 账户额度模型（v0.3.38）

/// 一个积分包：余额 + 到期。接口只给这两个字段，**没有来源类型、没有原始额度**（spec §3.1）。
public struct QwenWorkWallet: Codable, Sendable, Equatable {
    public let balance: Double
    public let validTo: Date?

    public init(balance: Double, validTo: Date?) {
        self.balance = balance
        self.validTo = validTo
    }
}

/// `GET /user/wallets`：三类合计 + 各包明细。
public struct QwenWorkWallets: Codable, Sendable, Equatable {
    public let daily: Double
    public let monthly: Double
    public let longterm: Double
    public let wallets: [QwenWorkWallet]

    public init(daily: Double, monthly: Double, longterm: Double, wallets: [QwenWorkWallet]) {
        self.daily = daily
        self.monthly = monthly
        self.longterm = longterm
        self.wallets = wallets
    }
}

/// `account-context` 的 `plan`：套餐 id 决定分母查哪一行套餐表。
public struct QwenWorkPlan: Codable, Sendable, Equatable {
    public let pid: String?
    public let name: String?
    public let isPersonal: Bool?

    public init(pid: String?, name: String?, isPersonal: Bool?) {
        self.pid = pid
        self.name = name
        self.isPersonal = isPersonal
    }

    /// 免费档（`subscription-cn-free`）：周期包 = 注册赠送，分母查 `starter_credits`。
    public var isFreeTier: Bool { (pid ?? "").lowercased().contains("free") }
}

/// `account-context` 的 `quota`：个人版只有 `remaining`；企业席位另有 `total / used`（累计口径）。
public struct QwenWorkAccountQuota: Codable, Sendable, Equatable {
    public let remaining: Double?
    public let total: Double?
    public let used: Double?

    public init(remaining: Double?, total: Double?, used: Double?) {
        self.remaining = remaining
        self.total = total
        self.used = used
    }
}

/// `GET /user/plans`（公开接口）里一档套餐的额度参数。
public struct QwenWorkPlanValues: Codable, Sendable, Equatable {
    /// 每天赠送多少（每日包额度）
    public let dailyTrialCredits: Double?
    /// 注册时一次性送多少（免费档的周期包原始额度）
    public let starterCredits: Double?
    /// 付费套餐每月发多少（付费档的周期包原始额度）
    public let monthlyCredits: Double?

    public init(dailyTrialCredits: Double?, starterCredits: Double?, monthlyCredits: Double?) {
        self.dailyTrialCredits = dailyTrialCredits
        self.starterCredits = starterCredits
        self.monthlyCredits = monthlyCredits
    }
}

/// 网页令牌这条线的状态（只影响「今日已用 / 按会话积分」，与剩余 / 每日 / 周期 / 长期无关）。
public enum QwenWorkWebSession: Sendable, Equatable {
    /// 精确模式关（默认）
    case off
    /// 有一张未过期的网页令牌
    case valid(expiresAt: Date, source: QwenWorkWebTokenRecord.Source)
    /// 曾有令牌但已过期（或被服务端拒绝）
    case expired(expiredAt: Date?)
    /// Chrome 钥匙串授权被拒，退避到 `until`
    case authDenied(until: Date)
    /// Chrome 里没有 qwenwork.cn 的登录
    case notFound
    /// 本机没有 Chrome 的 cookie 库
    case noBrowser

    public var isValid: Bool { if case .valid = self { return true } else { return false } }
}

/// 一类额度里的一个积分包（详情页行下小字）。
public struct QwenWorkPack: Sendable, Equatable {
    public let title: String
    public let grant: Double?
    public let remaining: Double
    public let validTo: Date?
}

/// 一类额度（每日 / 周期 / 长期）：主列表一颗药丸、详情页一行。
public struct QwenWorkQuotaCategory: Sendable, Equatable {
    public let id: String
    public let label: String
    public let remaining: Double
    /// 额度（能推断才有）；`remaining > grant` 时置 nil（活动日多送、多个包叠加）
    public let grant: Double?
    /// 企业席位直接给的累计已用（覆盖 `grant − remaining`）
    public let usedOverride: Double?
    public let resetsAt: Date?
    /// 「重置」还是「到期」
    public let resetVerb: String
    public let packs: [QwenWorkPack]

    public var used: Double? {
        if let usedOverride { return usedOverride }
        guard let grant else { return nil }
        return max(0, grant - remaining)
    }
}

/// 主列表药丸 + 详情页额度模块的数据源（v0.3.38 起替代旧的「余额 + 今日已用」两值）。
public struct QwenWorkQuota: Sendable, Equatable {
    /// 三类之和 = 官方「剩余可用」大字
    public let remainingTotal: Double?
    public let planName: String?
    public let categories: [QwenWorkQuotaCategory]
    /// 只有网页令牌有效时才有值
    public let todaySpent: Double?
    public let webSession: QwenWorkWebSession
    /// 桌面令牌这条线的错误（凭证失效 / 网络）；网页线的问题不进这里
    public let error: RateLimitError?
}

/// 千问办公积分：账户额度（桌面令牌）+ 账单流水（网页令牌）。
///
/// 两条线（spec §3.1，2026-09-08 探针实证）：
/// - **桌面线**：读千问办公 app 存在本机的登录令牌（`aud=oauth_app`），打
///   `gateway.qwenwork.cn/api/v1/adapter/user/account-context?include=quota,plan`（剩余 + 套餐；桌面 app 自己也用它）、
///   `qwenwork.cn/user/balance`（剩余后备）、`qwenwork.cn/user/wallets`（每日 / 周期 / 长期各包余额与到期）；
///   分母查公开的 `qwenwork.cn/user/plans`。
/// - **网页线**：`qwenwork.cn/user/billings` 只认网页登录的令牌（`aud=user`，48 小时）；桌面令牌打它稳定 403。
///   令牌来源见 `QwenWorkWebToken.swift`。账单 200 后照旧走 `replace` 差分流水，口径不变。
/// - `/user/billings/computer` 官方已下线（410），不再调用。
///
/// 缓存保存两层数据：
/// 1. **当前行快照**按来源整批替换，绝不把旧金额和新金额同时计入；
/// 2. **积分差分流水**：同一会话的旧行 amount 增长时，只把增量记到本次观察时间。
///
/// 第 2 层不能省：实测同会话 10:39 的新扣减会继续累加在 created_at=10:01 的旧行上。
/// 若会话跨日/跨周，直接按旧 created_at 汇总会把新消耗算回旧周期；差分流水才能满足按周统计。
public actor QwenWorkBillingStore {
    public static let shared = QwenWorkBillingStore()

    /// 当前缓存版本。
    ///
    /// ⚠️ 两次**不兼容**升级，都是流水本身算错了、无法就地修：
    /// - v3 → v4：v3 用「负数即消耗」，把「积分过期」记成了消耗，而 v3 的行没存 `type`；
    /// - v4 → v5：v4 的键在同秒多行时相撞，每次刷新都会多写一笔幽灵流水（见 `indexedKeys`）。
    ///
    /// v0.3.38 只**追加可选字段**（钱包 / 套餐 / 网关额度），版本不动，老文件照常解码。
    private static let cacheVersion = 5

    private struct CacheFile: Codable {
        let version: Int
        let updatedAt: Date
        let accountFingerprint: String?
        let records: [QwenWorkBillingRecord]
        let ledger: [QwenWorkCreditLedgerEntry]
        /// 剩余可用积分。离线时按最后一次成功值展示。
        let balance: Double?
        // —— v0.3.38 追加，全部可选 ——
        let wallets: QwenWorkWallets?
        let plan: QwenWorkPlan?
        let accountQuota: QwenWorkAccountQuota?
        let planCatalog: [String: QwenWorkPlanValues]?
        let planCatalogFetchedAt: Date?
        let lastWebSyncAt: Date?
    }

    enum FetchResult: Sendable {
        /// 原始响应体；解析放在 actor 里做（`Any` 不能跨并发域，`Data` 可以）
        case success(Data)
        case auth
        case failure
    }

    static let accountContextEndpoint =
        "https://gateway.qwenwork.cn/api/v1/adapter/user/account-context?include=quota,plan"
    static let balanceEndpoint = "https://qwenwork.cn/user/balance"
    static let walletsEndpoint = "https://qwenwork.cn/user/wallets"
    static let plansEndpoint = "https://qwenwork.cn/user/plans"
    static let billingsEndpoint = "https://qwenwork.cn/user/billings?source=all"
    /// 网页「用量明细」页：网页登录过期时让用户在 Chrome 里打开一次即可续新令牌。
    public static let usagePageURL = URL(string: "https://qwenwork.cn/app/settings/usage")!

    private let fileURL: URL
    private var accountFingerprint: String?
    private var cachedToken: String?
    private var records: [QwenWorkBillingRecord] = []
    private var ledger: [QwenWorkCreditLedgerEntry] = []
    private var balance: Double?
    private var wallets: QwenWorkWallets?
    private var plan: QwenWorkPlan?
    private var accountQuota: QwenWorkAccountQuota?
    private var planCatalog: [String: QwenWorkPlanValues] = [:]
    private var planCatalogFetchedAt: Date?
    /// 本进程内桌面线至少成功过一次
    private var desktopSynced = false
    /// 本进程内网页线（账单）最近一次同步成功、且令牌仍有效（`refresh` 里令牌失效就清掉）
    private var webSynced = false
    private var webSession: QwenWorkWebSession = .off
    private var lastWebSyncAt: Date?
    private var cachedWebToken: QwenWorkWebTokenRecord?
    private var loaded = false
    private var refreshInFlight = false
    private var lastRefreshAt: Date?
    private var lastError: RateLimitError?

    public static var defaultPath: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("usageBar", isDirectory: true)
            .appendingPathComponent("qwen-work-billings.json")
    }

    init(fileURL: URL = QwenWorkBillingStore.defaultPath) {
        self.fileURL = fileURL
    }

    /// 只清内存里的登录令牌；账单历史是用户要求保留的本地缓存，不随「重置授权」删除。
    public func clearAuthCache() {
        cachedToken = nil
    }

    /// 清掉网页令牌（钥匙串条目 + 内存 + 退避），下次刷新重新走 Chrome 导入。
    public func clearWebToken() {
        cachedWebToken = nil
        webSynced = false
        webSession = .off
        QwenWorkWebTokenKeychain.delete()
        QwenWorkChromeBackoff.clear()
    }

    /// 解除 Chrome 授权退避（设置页「重新授权」）。
    public func retryChromeAuthorization() {
        QwenWorkChromeBackoff.clear()
    }

    /// 手动粘贴 cURL / Cookie 头 / 裸 JWT。返回 nil = 没抽出令牌或已过期。
    @discardableResult
    public func setManualWebToken(_ text: String, now: Date = Date()) -> Date? {
        guard let token = QwenWorkWebTokenExtractor.extract(from: text),
              QwenWorkJWT.isUsable(token, now: now),
              let exp = QwenWorkJWT.expiry(token) else { return nil }
        let record = QwenWorkWebTokenRecord(token: token, source: .manual, savedAt: now)
        QwenWorkWebTokenKeychain.save(record)
        cachedWebToken = record
        QwenWorkChromeBackoff.clear()
        lastRefreshAt = nil   // 让下一次 refresh 立即生效
        return exp
    }

    public func currentWebSession() -> QwenWorkWebSession { webSession }

    /// 返回从账单快照差分出的本地流水。首次调用会从磁盘恢复，离线时仍可按周期查看。
    func cachedLedger() -> [QwenWorkCreditLedgerEntry] {
        loadIfNeeded()
        return ledger
    }

    func cachedHistory() -> QwenWorkCreditHistory {
        loadIfNeeded()
        return QwenWorkCreditHistory(ledger: ledger, isAvailable: webSynced, lastSyncAt: lastWebSyncAt)
    }

    // MARK: - 额度

    /// 主列表药丸 + 详情页额度模块。
    public func quota(now: Date = Date()) -> QwenWorkQuota {
        loadIfNeeded()
        let categories = Self.categories(
            wallets: wallets, plan: plan, accountQuota: accountQuota,
            catalog: planCatalog, now: now)
        let remainingTotal = accountQuota?.remaining ?? balance
            ?? (wallets.map { $0.daily + $0.monthly + $0.longterm })
        let spent: Double? = webSynced ? todaySpent(now: now) : nil
        return QwenWorkQuota(
            remainingTotal: remainingTotal,
            planName: plan?.name,
            categories: categories,
            todaySpent: spent,
            webSession: webSession,
            // 有过一次成功就先显示数；只有「从没成功过」才把错误抛给 UI。
            error: (desktopSynced || wallets != nil || balance != nil) ? nil : lastError)
    }

    private func todaySpent(now: Date) -> Double {
        let today = DailyAggregator.dateString(for: now)
        return max(0, ledger
            .filter { DailyAggregator.dateString(for: $0.occurredAt) == today }
            .reduce(0.0) { $0 + $1.credits })
    }

    /// 把钱包 / 套餐 / 网关额度拼成三类（spec §3.1 的推断规则，纯函数、有测试）。
    ///
    /// - 每日：分子 = 每日包合计；分母 = 套餐表 `daily_trial_credits`；分子 > 分母（活动日多送）→ 无分母。
    /// - 周期：企业席位（`quota.total` 非空）直接用 total/used；否则分子 = 周期包合计，
    ///   分母 = 免费档 `starter_credits` / 付费档 `monthly_credits`；分子 > 分母（充值、活动叠加）→ 无分母。
    /// - 长期：只有合计，接口没有「额度」概念。
    /// - 包的来源类型只能按到期规律推断：到期在 36 小时内 = 每日包，其余 = 周期包；周期类只有一个包时
    ///   才把类的额度写到包上，多个包时各包额度未知。
    static func categories(
        wallets: QwenWorkWallets?, plan: QwenWorkPlan?, accountQuota: QwenWorkAccountQuota?,
        catalog: [String: QwenWorkPlanValues], now: Date
    ) -> [QwenWorkQuotaCategory] {
        guard let wallets else {
            // 只有网关额度（企业席位常见）：给一行周期
            if let quota = accountQuota, let total = quota.total, total > 0 {
                let remaining = quota.remaining ?? max(0, total - (quota.used ?? 0))
                return [QwenWorkQuotaCategory(
                    id: "period", label: "周期", remaining: remaining, grant: total,
                    usedOverride: quota.used, resetsAt: nil, resetVerb: "到期", packs: [])]
            }
            return []
        }
        let values = plan?.pid.flatMap { catalog[$0] }
        let dailyCutoff = now.addingTimeInterval(36 * 3600)
        let dailyPacks = wallets.wallets.filter { ($0.validTo ?? .distantFuture) <= dailyCutoff }
        let periodPacks = wallets.wallets.filter { ($0.validTo ?? .distantFuture) > dailyCutoff }

        // 每日
        let dailyGrant = values?.dailyTrialCredits
        let dailyCategory = QwenWorkQuotaCategory(
            id: "daily", label: "每日", remaining: wallets.daily,
            grant: (dailyGrant.map { $0 > 0 && wallets.daily <= $0 + 0.0001 } ?? false) ? dailyGrant : nil,
            usedOverride: nil,
            resetsAt: dailyPacks.compactMap(\.validTo).min(),
            resetVerb: "清零",
            packs: dailyPacks.map {
                QwenWorkPack(title: "每日赠送", grant: dailyGrant, remaining: $0.balance, validTo: $0.validTo)
            })

        // 周期
        let periodCategory: QwenWorkQuotaCategory
        if let quota = accountQuota, let total = quota.total, total > 0 {
            let remaining = quota.remaining ?? max(0, total - (quota.used ?? 0))
            periodCategory = QwenWorkQuotaCategory(
                id: "period", label: "周期", remaining: remaining, grant: total,
                usedOverride: quota.used, resetsAt: periodPacks.compactMap(\.validTo).min(),
                resetVerb: "到期",
                packs: periodPacks.map { QwenWorkPack(title: "席位套餐", grant: nil, remaining: $0.balance, validTo: $0.validTo) })
        } else {
            let isFree = plan?.isFreeTier ?? true
            let periodGrant = isFree ? values?.starterCredits : values?.monthlyCredits
            let periodTitle = isFree ? "注册赠送 (starter)" : "套餐月度"
            let remaining = wallets.monthly
            let grantOK = (periodGrant.map { $0 > 0 && remaining <= $0 + 0.0001 } ?? false)
            periodCategory = QwenWorkQuotaCategory(
                id: "period", label: "周期", remaining: remaining,
                grant: grantOK ? periodGrant : nil, usedOverride: nil,
                resetsAt: periodPacks.compactMap(\.validTo).min(), resetVerb: "到期",
                packs: periodPacks.map {
                    QwenWorkPack(title: periodPacks.count == 1 ? periodTitle : "积分包",
                                 grant: (periodPacks.count == 1 && grantOK) ? periodGrant : nil,
                                 remaining: $0.balance, validTo: $0.validTo)
                })
        }

        // 长期
        let longtermCategory = QwenWorkQuotaCategory(
            id: "longterm", label: "长期", remaining: wallets.longterm, grant: nil,
            usedOverride: nil, resetsAt: nil, resetVerb: "到期", packs: [])

        return [dailyCategory, periodCategory, longtermCategory]
    }

    /// 展示用格式化："2,437.02"（两位小数 + 千分位，与官方「我的积分」页一致）。
    public static func formatCredits(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    // MARK: - 刷新

    /// 刷新两条线。任一路失败都保留该路旧缓存；其余路成功仍会独立更新。
    ///
    /// - `preciseMode`：设置页「精确模式 · 读取 Chrome 里的网页登录」的开关；关着就不碰 Chrome、不打账单。
    /// - 30 秒内的重复调用直接复用缓存，避免“打开详情 + 主刷新”同时触发两次请求。
    @discardableResult
    public func refresh(now: Date = Date(), force: Bool = false, preciseMode: Bool = false) async -> Bool {
        loadIfNeeded()
        if !force, let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < 30 {
            return true
        }
        // actor 在网络 await 期间可重入；显式拦住并发刷新，避免同一轮发两组请求。
        guard !refreshInFlight else { return true }
        refreshInFlight = true
        defer { refreshInFlight = false }

        let desktopOK = await refreshDesktopLine(now: now)
        await refreshPlanCatalog(now: now)
        webSession = await refreshWebLine(now: now, preciseMode: preciseMode)
        // 网页线只要不是「有效」，本进程内的账单同步就作废：详情页不能拿旧账本冒充今日数字
        if !webSession.isValid { webSynced = false }
        if desktopOK { lastRefreshAt = now }
        persist(updatedAt: now)
        return desktopOK
    }

    // MARK: 桌面线

    private struct DesktopFetch {
        let context: FetchResult
        let balance: FetchResult
        let wallets: FetchResult

        var anySuccess: Bool {
            [context, balance, wallets].contains { if case .success = $0 { return true } else { return false } }
        }
        /// 三路里没有任何一路成功、且至少一路明确说凭证不对 → 令牌坏了
        var authFailed: Bool {
            !anySuccess && [context, balance, wallets].contains { if case .auth = $0 { return true } else { return false } }
        }
    }

    private func refreshDesktopLine(now: Date) async -> Bool {
        var token = cachedToken ?? acquireToken()
        guard let first = token else {
            lastError = .credentialUnavailable
            return false
        }
        var result = await fetchDesktop(token: first)
        if result.authFailed, cachedToken != nil {
            // 内存里的旧令牌可能已被 app 换掉：从磁盘重读一次再试
            cachedToken = nil
            if let fresh = acquireToken(), fresh != first {
                token = fresh
                result = await fetchDesktop(token: fresh)
            }
        }
        if result.authFailed {
            cachedToken = nil
            lastError = .credentialUnavailable
            return false
        }
        guard result.anySuccess else {
            lastError = .network
            return false
        }
        cachedToken = token
        selectAccount(token.flatMap(Self.accountFingerprint(from:)))
        if case .success(let data) = result.context, let root = Self.json(data) {
            if let quota = Self.parseAccountQuota(root) { accountQuota = quota }
            if let parsed = Self.parsePlan(root) { plan = parsed }
        }
        if case .success(let data) = result.balance, let root = Self.json(data), let value = Self.parseBalance(root) {
            balance = value
        }
        if case .success(let data) = result.wallets, let root = Self.json(data), let parsed = Self.parseWallets(root) {
            wallets = parsed
        }
        desktopSynced = true
        lastError = nil
        return true
    }

    private func fetchDesktop(token: String) async -> DesktopFetch {
        async let context = Self.requestJSON(Self.accountContextEndpoint, token: token, userAgent: "qoderwork")
        async let balance = Self.requestJSON(Self.balanceEndpoint, token: token)
        async let wallets = Self.requestJSON(Self.walletsEndpoint, token: token)
        return await DesktopFetch(context: context, balance: balance, wallets: wallets)
    }

    /// 套餐表是公开接口，一天拉一次够用（分母：免费 100 / Plus 200 / Pro 300 / 企业 150）。
    private func refreshPlanCatalog(now: Date) async {
        if let at = planCatalogFetchedAt, now.timeIntervalSince(at) < 24 * 3600, !planCatalog.isEmpty { return }
        guard case .success(let data) = await Self.requestJSON(Self.plansEndpoint, token: nil),
              let root = Self.json(data),
              let parsed = Self.parsePlanCatalog(root), !parsed.isEmpty else { return }
        planCatalog = parsed
        planCatalogFetchedAt = now
    }

    // MARK: 网页线

    private func refreshWebLine(now: Date, preciseMode: Bool) async -> QwenWorkWebSession {
        guard preciseMode else { return .off }

        // 1) usageBar 自己的钥匙串缓存
        if cachedWebToken == nil { cachedWebToken = QwenWorkWebTokenKeychain.load() }
        var record = cachedWebToken
        if let r = record, !QwenWorkJWT.isUsable(r.token, now: now) { record = nil }

        // 2) Chrome cookie 自动导入（授权被拒过就等退避结束）
        var importOutcome: ChromeCookieReader.Outcome?
        if record == nil {
            if let until = QwenWorkChromeBackoff.deniedUntil(now: now) {
                return .authDenied(until: until)
            }
            let outcome = ChromeCookieReader.qwenWorkToken(now: now)
            importOutcome = outcome
            switch outcome {
            case .token(let token) where QwenWorkJWT.isUsable(token, now: now):
                let fresh = QwenWorkWebTokenRecord(token: token, source: .chrome, savedAt: now)
                QwenWorkWebTokenKeychain.save(fresh)
                record = fresh
            case .denied:
                QwenWorkChromeBackoff.noteDenied(now: now)
                return .authDenied(until: now.addingTimeInterval(QwenWorkChromeBackoff.duration))
            default:
                break
            }
        }
        guard let record else {
            let previous = cachedWebToken?.expiresAt
            cachedWebToken = nil
            if let previous { return .expired(expiredAt: previous) }
            if case .noBrowser = importOutcome { return .noBrowser }
            return .notFound
        }
        cachedWebToken = record

        // 3) 打账单
        let result = await Self.requestJSON(Self.billingsEndpoint, token: record.token)
        switch result {
        case .success(let data):
            guard let root = Self.json(data), let rows = Self.parseBillings(root) else {
                return .valid(expiresAt: record.expiresAt ?? now, source: record.source)
            }
            replace(origin: .billings, with: rows, observedAt: now)
            webSynced = true
            return .valid(expiresAt: record.expiresAt ?? now, source: record.source)
        case .auth:
            // 服务端不认这张票：清掉缓存，下一轮重新导入
            QwenWorkWebTokenKeychain.delete()
            cachedWebToken = nil
            return .expired(expiredAt: record.expiresAt)
        case .failure:
            // 网络错：令牌本身还有效，保留
            return .valid(expiresAt: record.expiresAt ?? now, source: record.source)
        }
    }

    // MARK: - 网络与认证

    private static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    private static func requestJSON(_ endpoint: String, token: String?, userAgent: String = "usageBar") async -> FetchResult {
        guard let url = URL(string: endpoint) else { return .failure }
        var req = URLRequest(url: url, timeoutInterval: 12)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure }
            switch http.statusCode {
            case 200: break
            case 401, 403: return .auth
            default: return .failure
            }
            return .success(data)
        } catch {
            return .failure
        }
    }

    /// QwenWorkCN Electron safeStorage：auth-v2.dat / auth.dat +
    /// 钥匙串 `QwenWorkCN Safe Storage`。解密算法与 QoderWork 完全相同，复用已审计实现。
    private func acquireToken() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenWorkCN")
        let files = ["auth-v2.dat", "auth.dat"].map { dir.appendingPathComponent($0) }
        guard files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let key = QoderRateLimitReader.deriveKey(service: "QwenWorkCN Safe Storage")
        else { return nil }

        for url in files {
            guard let encrypted = try? Data(contentsOf: url),
                  let decrypted = QoderRateLimitReader.decrypt(encrypted, key: key),
                  let object = try? JSONSerialization.jsonObject(with: decrypted),
                  let token = QoderRateLimitReader.findToken(in: object),
                  !token.isEmpty
            else { continue }
            return token
        }
        return nil
    }

    // MARK: - 响应解析

    /// 兼容 `{"data":{"balance":…}}` 与直给 `{"balance":…}`。
    static func parseBalance(_ root: Any) -> Double? {
        guard let object = root as? [String: Any] else { return nil }
        if let value = number(object["balance"]) { return value }
        guard let data = object["data"] as? [String: Any] else { return nil }
        return number(data["balance"])
    }

    /// `account-context` → `data.quota.{remaining,total,used}`（个人版 total/used 为 null）。
    static func parseAccountQuota(_ root: Any) -> QwenWorkAccountQuota? {
        guard let data = dataObject(root), let quota = data["quota"] as? [String: Any] else { return nil }
        let q = QwenWorkAccountQuota(
            remaining: number(quota["remaining"]), total: number(quota["total"]), used: number(quota["used"]))
        return q.remaining == nil && q.total == nil ? nil : q
    }

    /// `account-context` → `data.plan.{pid,name,is_personal_version}`。
    static func parsePlan(_ root: Any) -> QwenWorkPlan? {
        guard let data = dataObject(root), let plan = data["plan"] as? [String: Any] else { return nil }
        return QwenWorkPlan(
            pid: nonEmpty(plan["pid"] as? String),
            name: nonEmpty(plan["name"] as? String),
            isPersonal: plan["is_personal_version"] as? Bool)
    }

    /// `/user/wallets` → 三类合计 + 各包。
    static func parseWallets(_ root: Any) -> QwenWorkWallets? {
        guard let data = dataObject(root) else { return nil }
        func total(_ key: String) -> Double {
            number((data[key] as? [String: Any])?["total_balance"]) ?? 0
        }
        let rows = ((data["active_wallets"] as? [String: Any])?["wallets"] as? [[String: Any]]) ?? []
        let wallets = rows.compactMap { row -> QwenWorkWallet? in
            guard let balance = number(row["balance"]) else { return nil }
            return QwenWorkWallet(balance: balance, validTo: (row["valid_to"] as? String).flatMap(parseDate))
        }
        guard data["daily_credits"] != nil || data["monthly_credits"] != nil || !wallets.isEmpty else { return nil }
        return QwenWorkWallets(
            daily: total("daily_credits"), monthly: total("monthly_credits"),
            longterm: total("longterm_credits"), wallets: wallets)
    }

    /// `/user/plans` → `pid → values`。
    static func parsePlanCatalog(_ root: Any) -> [String: QwenWorkPlanValues]? {
        guard let object = root as? [String: Any], let rows = object["data"] as? [[String: Any]] else { return nil }
        var out: [String: QwenWorkPlanValues] = [:]
        for row in rows {
            guard let pid = nonEmpty(row["pid"] as? String), let values = row["values"] as? [String: Any] else { continue }
            out[pid] = QwenWorkPlanValues(
                dailyTrialCredits: number(values["daily_trial_credits"]),
                starterCredits: number(values["starter_credits"]),
                monthlyCredits: number(values["monthly_credits"]))
        }
        return out
    }

    /// `/user/billings` 的兼容解析，与官网前端的 data/items/billings/records 解包顺序一致。
    static func parseBillings(_ root: Any) -> [QwenWorkBillingRecord]? {
        guard let rows = unwrapRows(root) else { return nil }
        return rows.compactMap { row in
            guard let amount = number(row["amount"]),
                  let rawDate = row["created_at"] as? String,
                  let createdAt = parseDate(rawDate)
            else { return nil }
            let detailObject = row["detail"] as? [String: Any]
            let title = nonEmpty(detailObject?["title"] as? String) ?? "—"
            let rawSource = firstNonEmpty([
                row["consume_source"],
                row["client_name"],
                row["client_type"],
                row["platform"],
                row["source"],
                detailObject?["source"],
            ])
            let source = rawSource ?? (amount < 0 ? "网页版" : "—")
            let serverId = firstNonEmpty([
                row["id"],
                row["billing_id"],
                row["transaction_id"],
                row["order_id"],
            ])
            return QwenWorkBillingRecord(
                amount: amount,
                createdAt: createdAt,
                source: source,
                detail: title,
                origin: .billings,
                serverId: serverId,
                // ⛔ 这个字段是「负数是不是消耗」的唯一判据，别省（见 QwenWorkBillingRecord 头注）
                type: nonEmpty(row["type"] as? String)
            )
        }
    }

    private static func dataObject(_ root: Any) -> [String: Any]? {
        guard let object = root as? [String: Any] else { return nil }
        return (object["data"] as? [String: Any]) ?? object
    }

    private static func unwrapRows(_ root: Any) -> [[String: Any]]? {
        var current: Any = root
        for _ in 0..<3 {
            if current is NSNull { return [] }
            if let rows = current as? [[String: Any]] { return rows }
            guard let object = current as? [String: Any] else { return nil }
            let next = object["data"]
                ?? object["items"]
                ?? object["billings"]
                ?? object["records"]
            guard let next else { return nil }
            current = next
        }
        if current is NSNull { return [] }
        return current as? [[String: Any]]
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISODateParser.parse(value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonEmpty(_ values: [Any?]) -> String? {
        for case let value as String in values {
            if let value = nonEmpty(value) { return value }
        }
        return nil
    }

    /// JWT 只取稳定账号标识并立即哈希；token、email、user_id 都不会写入缓存。
    /// 旧版/非 JWT token 返回 nil，此时保持向后兼容但不做账号切换判断。
    static func accountFingerprint(from token: String) -> String? {
        guard let object = QwenWorkJWT.claims(token),
              let identifier = firstNonEmpty([
                  object["user_id"],
                  object["sub"],
                  object["email"],
              ])
        else { return nil }
        let digest = SHA256.hash(data: Data("qwen-work|\(identifier)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 缓存替换

    /// 切换千问账号时清空上一账号的行、差分流水与余额，防止跨账号合计。
    /// 账号未知时仅补 fingerprint，不丢已有历史。
    func selectAccount(_ incoming: String?) {
        guard let incoming else { return }
        if let current = accountFingerprint, current != incoming {
            records.removeAll()
            ledger.removeAll()
            balance = nil
            wallets = nil
            accountQuota = nil
        }
        accountFingerprint = incoming
    }

    /// 给账单行生成**真正唯一**的键：`identityKey` + 组内序号。
    ///
    /// ⛔ 为什么必须加序号（2026-08-04 实测抓到的持续虚增 bug）：服务端同一秒会返回多条账单，
    /// 它们的 created_at / source / detail 完全一样 → `identityKey` 相撞。相撞后：
    /// - `previous` 字典只留下第一条（`uniquingKeysWith: first`）；
    /// - 循环到第二条时拿第一条的金额当基线，差出一个**非零** delta 并写进流水；
    /// - 下一次刷新重复同样的计算 → **每刷新一次就多记一笔**，永远不收敛。
    ///
    /// 实测现场：一条 7-30 的旧行被写了 5 遍、每遍 0.3847，把当天总额从 2.67 顶到 4.59。
    ///
    /// 序号按**服务端返回顺序**编（所以 `records` 不再排序，见 `replace` 末尾）；第 0 条沿用原 key，
    /// 让已有流水的 recordKey 保持可对应。
    static func indexedKeys(_ records: [QwenWorkBillingRecord]) -> [String] {
        var seen: [String: Int] = [:]
        return records.map { record in
            let n = seen[record.identityKey, default: 0]
            seen[record.identityKey] = n + 1
            return n == 0 ? record.identityKey : "\(record.identityKey)#\(n)"
        }
    }

    /// 同来源整批替换，同时把 amount 变化转成一条增量流水：
    /// - 新行：完整扣减归到服务端 created_at；
    /// - 已见行：新旧 spend 差归到 observedAt，解决跨日/跨周会话仍沿用旧时间的问题；
    /// - 数值未变：不写流水。
    func replace(
        origin: QwenWorkBillingRecord.Origin,
        with fetched: [QwenWorkBillingRecord],
        observedAt: Date = Date()
    ) {
        loadIfNeeded()
        webSynced = true
        lastWebSyncAt = observedAt
        let previousRecords = records.filter { $0.origin == origin }
        let previous = Dictionary(
            uniqueKeysWithValues: zip(Self.indexedKeys(previousRecords), previousRecords)
        )
        // 接口理论上返回完整历史；仍以已有流水合计作第二基线，防止某行短暂缺席后
        // 再出现时被当成新行重复计费。
        var accumulated = Dictionary(grouping: ledger, by: \.recordKey)
            .mapValues { $0.reduce(0.0) { $0 + $1.credits } }
        for (key, record) in zip(Self.indexedKeys(fetched), fetched) {
            let wasSeen = previous[key] != nil || accumulated[key] != nil
            let oldSpent = previous[key]?.spent ?? accumulated[key] ?? 0
            let delta = record.spent - oldSpent
            guard abs(delta) > 0.000_000_1 else { continue }
            ledger.append(QwenWorkCreditLedgerEntry(
                credits: delta,
                occurredAt: wasSeen ? observedAt : record.createdAt,
                recordKey: key,
                origin: origin
            ))
            accumulated[key] = oldSpent + delta
        }
        records.removeAll { $0.origin == origin }
        records.append(contentsOf: fetched)
        // ⚠️ 不排序：序号编在服务端返回顺序上，重排会让同秒行的序号在两次刷新间错位
        // （Swift 的 sort 不保证稳定），差分基线就又对不上了。
        persist(updatedAt: observedAt)
    }

    /// 测试用：直接灌入桌面线的解析结果，不走网络。
    func seedForTesting(wallets: QwenWorkWallets?, plan: QwenWorkPlan?, accountQuota: QwenWorkAccountQuota?,
                        catalog: [String: QwenWorkPlanValues], balance: Double?, webSession: QwenWorkWebSession) {
        loadIfNeeded()
        self.wallets = wallets
        self.plan = plan
        self.accountQuota = accountQuota
        self.planCatalog = catalog
        self.balance = balance
        self.webSession = webSession
        self.desktopSynced = true
    }

    /// 只接受当前版本的缓存。
    ///
    /// ⚠️ **不做 v1–v4 迁移是刻意的**：v1–v3 的流水把「积分过期」算成了消耗（且行里没有 `type` 可供判断），
    /// v4 的流水含同秒撞键产生的幽灵条目——两种坏数据都无法就地识别并剔除。
    /// 服务端每次返回完整历史，弃用旧缓存下一次刷新就全回来了；保留错数据只会一直错下去。
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(CacheFile.self, from: data),
              cache.version == Self.cacheVersion
        else { return }
        accountFingerprint = cache.accountFingerprint
        records = cache.records
        ledger = cache.ledger
        balance = cache.balance
        wallets = cache.wallets
        plan = cache.plan
        accountQuota = cache.accountQuota
        planCatalog = cache.planCatalog ?? [:]
        planCatalogFetchedAt = cache.planCatalogFetchedAt
        lastWebSyncAt = cache.lastWebSyncAt
        // 不把 lastRefreshAt 设成缓存时间：启动后第一轮就该去刷新，而不是等 30 秒节流
    }

    private func persist(updatedAt: Date) {
        let file = CacheFile(
            version: Self.cacheVersion,
            updatedAt: updatedAt,
            accountFingerprint: accountFingerprint,
            records: records,
            ledger: ledger,
            balance: balance,
            wallets: wallets,
            plan: plan,
            accountQuota: accountQuota,
            planCatalog: planCatalog.isEmpty ? nil : planCatalog,
            planCatalogFetchedAt: planCatalogFetchedAt,
            lastWebSyncAt: lastWebSyncAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
