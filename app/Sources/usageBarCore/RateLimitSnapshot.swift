import Foundation

/// 账号额度快照模型（v0.3.24）。
///
/// 与「历史 token 用量」（`StatRecord` 按日聚合）完全独立：额度是**某一时刻的账号窗口状态**，
/// 不是按日累加的量。设计成**窗口数组**而非固定字段——因为窗口数量和长度都是动态的：
/// - Claude 有 3 条（5h / 7d / 分模型 Fable）；Codex 实测只有 1 条 7 天窗（`secondary` 为 null）。
/// - ⚠️ 窗口 label **必须按 `windowMinutes` 推导**，别按名字写死（2026-07-14 探针实证 Codex 的 primary
///   不再是 5 小时窗而是 7 天窗，见 `docs/0714-账号额度与昨日tab/账号额度与昨日tab-spec.md` §1c）。
///
/// 将来做小组件时，`RateLimitStore` 的路径换成 App Group 共享容器即可，本模型不动。

/// 单个额度窗口
public struct RateLimitWindow: Codable, Sendable, Equatable {
    /// 窗口种类原始标识：`"session"` / `"weekly_all"` / `"weekly_scoped"` / `"monthly"` 等
    public let kind: String
    /// 展示名（由 windowMinutes 或 scope 推导后落定）："5h" / "7d" / "Fable" / "月"
    public let label: String
    /// ⚠️ 官方给的原始窗口长度（分钟）。300→"5h"、10080→"7d"。有它就别按名字写死 label。
    public let windowMinutes: Int?
    /// 已用百分比 0–100
    public let usedPercent: Double
    /// 该窗口下次重置的时间点；月配额可空
    public let resetsAt: Date?
    /// 官方给的严重程度 `"normal"` / `"warning"` 等；nil 时 UI 用本地阈值兜底
    public let severity: String?
    /// 分模型限额的模型名（如 "Fable"），非分模型窗口为 nil
    public let scopeModel: String?
    /// used/total 附注，如 "1,234/5,000"（Qoder / WorkBuddy 信用点配额用；统一走 `usedOfTotal`）。
    /// v0.3.25 起详情页额度行与主列表药丸都会渲染它（0715 对焦稿 B1/P1 定稿），保持紧凑。
    public let detail: String?
    /// 原始已用数（信用点池用；`detail` 只是它的展示格式化）。v0.3.26 供额度历史记录做变化判断与分析，
    /// 百分比型窗口（Claude/Codex）为 nil。可选字段，老快照 JSON 解码自动得 nil，向后兼容。
    public let used: Double?
    /// 原始总额（同上）
    public let total: Double?
    /// **代替百分比展示的原样数值**（如千问办公的 "2,437.02"）。非 nil 时药丸/额度行显示它而不是 `usedPercent`。
    ///
    /// ⚠️ 为什么需要这个：千问办公的官方界面**根本没有「总额」概念**（只有「剩余可用」），
    /// 分母只能从流水反推、且每天都在变（平时每日赠 100、搞活动 500）——显示百分比会跳得没道理、
    /// 且与官方页面对不上账。所以这类 provider 直接展示余额/已用的绝对值。
    /// 详见 `docs/0804-千问办公接入/千问办公接入-spec.md` §2a（含百分比方案的否决理由）。
    public let valueText: String?

    public init(kind: String, label: String, windowMinutes: Int? = nil, usedPercent: Double,
                resetsAt: Date? = nil, severity: String? = nil, scopeModel: String? = nil,
                detail: String? = nil, used: Double? = nil, total: Double? = nil,
                valueText: String? = nil) {
        self.kind = kind
        self.label = label
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.severity = severity
        self.scopeModel = scopeModel
        self.detail = detail
        self.used = used
        self.total = total
        self.valueText = valueText
    }

    /// "6,000/6,000" —— `detail` 字段的统一紧凑格式（千分位、无单位；单位在信用点语境下自明）
    public static func usedOfTotal(_ used: Double, _ total: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        let u = f.string(from: NSNumber(value: used)) ?? String(Int(used))
        let t = f.string(from: NSNumber(value: total)) ?? String(Int(total))
        return "\(u)/\(t)"
    }

    /// 由 `windowMinutes` 推导展示 label（探针铁律：别按窗口名写死）。
    /// 300→"5h"、10080→"7d"，其余按最接近的小时/天算。
    public static func label(forWindowMinutes m: Int) -> String {
        switch m {
        case 300: return "5h"
        case 10080: return "7d"
        default:
            if m % 1440 == 0 { return "\(m / 1440)d" }
            if m % 60 == 0 { return "\(m / 60)h" }
            return "\(m)m"
        }
    }
}

/// 按量积分（Codex credits，0812 spec §二.5）。`balance` 保留官方原始字符串（"0" / "4.20"）。
public struct RateLimitCredits: Codable, Sendable, Equatable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    /// 药丸/详情页的展示值；nil = 不展示（拍板 1a：仅 unlimited 或余额 > 0 时出现）。
    public var displayText: String? {
        if unlimited { return "∞" }
        guard let balance, let v = Double(balance), v > 0 else { return nil }
        // 官方 balance 是美元字符串；两位小数、去多余零（"4.20"→"$4.20"、"12"→"$12"）
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        return "$\(s)"
    }
}

/// 企业/团队人均花费上限（individual_limit，美元字符串 + 剩余百分比）。
public struct RateLimitSpendCap: Codable, Sendable, Equatable {
    public let limit: String
    public let used: String
    public let remainingPercent: Double?
    public let resetsAt: Date?

    public init(limit: String, used: String, remainingPercent: Double?, resetsAt: Date?) {
        self.limit = limit
        self.used = used
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    /// 已用百分比（进度条用）；官方给的是剩余，这里翻转
    public var usedPercent: Double { max(0, min(100, 100 - (remainingPercent ?? 100))) }

    /// "$18.50/$50" —— 美元字符串直接拼接（保留官方原始精度）
    public var usedOfLimitText: String {
        func fmt(_ s: String) -> String {
            guard let v = Double(s) else { return s }
            return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        }
        return "$\(fmt(used))/$\(fmt(limit))"
    }
}

/// 限额重置券（rate_limit_reset_credits 的单张券）。
public struct RateLimitResetCoupon: Codable, Sendable, Equatable {
    /// "Full reset" 等官方标题；可空
    public let title: String?
    /// "available" / "redeemed" / "expired"…（原样保留，展示层只挑 available）
    public let status: String
    public let expiresAt: Date?

    public init(title: String?, status: String, expiresAt: Date?) {
        self.title = title
        self.status = status
        self.expiresAt = expiresAt
    }
}

/// 某 provider 某次采集时刻的完整额度快照
public struct RateLimitSnapshot: Codable, Sendable, Equatable {
    public let providerId: String
    /// ⚠️ 数量动态：可能 1 条也可能 3 条
    public let windows: [RateLimitWindow]
    /// 套餐名："max" / "prolite" / "Community" / "pro_plus"…，仅作展示。
    /// ⚠️ 开放集合（Codex 实测 20 档且官方留了 unknown 兜底）——原样展示，绝不枚举写死。
    public let planType: String?
    /// 本次采集时刻（本地时钟）
    public let capturedAt: Date
    /// 采集失败原因（超时/未登录/凭证失效/无配额数据/无数据源）；非 nil 时 windows 可能为空
    public let error: RateLimitError?
    // —— 以下 0812 新增（Codex RPC 全量字段）；全部可选，老快照 JSON 解码自动 nil ——
    /// 按量积分
    public let credits: RateLimitCredits?
    /// 企业/团队人均花费上限
    public let spendCap: RateLimitSpendCap?
    /// 已达管理员支出管控（true 时 UI 出红条）
    public let spendControlReached: Bool?
    /// 限流原因原始值（"rate_limit_reached" 等 5 种，文案映射在 UI 层）
    public let rateLimitReachedType: String?
    /// 重置券（含非 available 的；展示层过滤）
    public let resetCoupons: [RateLimitResetCoupon]?
    /// **这份数据（或这个失败）是谁给的**——如 "QoderWork" / "Qoder IDE" / "Qoder CLI"（v0.3.37 新增）。
    ///
    /// ⚠️ 为什么必须有：Qoder 家族里一行的额度可能由**另一个产品的凭证**代领（三端同账号时共用一个额度池）。
    /// 没有这个字段，UI 就只能说「登录凭证已失效」——可失效的其实是 QoderWork 的凭证，
    /// Qoder CLI 本身好好的。外部用户 2026-08-28 报的就是这个误报。
    /// 可选字段，老快照 JSON 解码自动得 nil，向后兼容。
    public let sourceLabel: String?

    public init(providerId: String, windows: [RateLimitWindow], planType: String? = nil,
                capturedAt: Date, error: RateLimitError? = nil,
                credits: RateLimitCredits? = nil, spendCap: RateLimitSpendCap? = nil,
                spendControlReached: Bool? = nil, rateLimitReachedType: String? = nil,
                resetCoupons: [RateLimitResetCoupon]? = nil,
                sourceLabel: String? = nil) {
        self.providerId = providerId
        self.windows = windows
        self.planType = planType
        self.capturedAt = capturedAt
        self.error = error
        self.credits = credits
        self.spendCap = spendCap
        self.spendControlReached = spendControlReached
        self.rateLimitReachedType = rateLimitReachedType
        self.resetCoupons = resetCoupons
        self.sourceLabel = sourceLabel
    }

    /// 可用的重置券（详情页逐张列出、主列表 "券 ×N"）
    public var availableCoupons: [RateLimitResetCoupon] {
        (resetCoupons ?? []).filter { $0.status == "available" }
    }

    /// 「最紧窗口」= usedPercent 最高的那个（主列表药丸只显示这一个的场景可能会用；本版药丸子行全显）。
    public var tightestWindow: RateLimitWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// 复制成另一个 providerId。
    ///
    /// ⚠️ v0.3.37 起 Qoder 家族**不再**用它把一个快照铺到 CLI / IDE 两行——那正是「Work 凭证失败
    /// 被显示成 Qoder CLI 登录失效」的成因（见 `QoderRateLimitReader.readAll`）。保留此方法给别处用。
    public func with(providerId newId: String) -> RateLimitSnapshot {
        RateLimitSnapshot(providerId: newId, windows: windows, planType: planType,
                          capturedAt: capturedAt, error: error,
                          credits: credits, spendCap: spendCap,
                          spendControlReached: spendControlReached,
                          rateLimitReachedType: rateLimitReachedType,
                          resetCoupons: resetCoupons,
                          sourceLabel: sourceLabel)
    }
}

/// 采集失败的分类（对应 spec §2.5 状态机的错误态）
public enum RateLimitError: String, Codable, Sendable, Equatable {
    /// 凭证读不到 / 钥匙串拒绝 / 401 过期 —— 用户「用一次工具后自动恢复」或点重试。
    /// ⚠️ 配 `RateLimitSnapshot.sourceLabel` 一起看：失效的是**那个来源**的凭证，不一定是本行这个工具
    case credentialUnavailable
    /// 用户在钥匙串授权框点了「拒绝」—— 不再自动重试，给重新授权入口
    case authDenied
    /// 网络错 / 超时 / 429 —— 保留上次快照
    case network
    /// 接口返回了但解析不出配额数字（教育/企业订阅等）
    case noQuotaData
    /// 该 provider 本就没有额度接口（WorkBuddy / 悟空…）
    case noDataSource
    /// statusline 已配置但还没数据（Claude 尚未刷新状态栏写入文件）—— 零钥匙串路线特有的「等待」态，非错误
    case awaitingData
    /// 找不到可用的 CLI 二进制（Codex RPC 数据源：发现链全空）—— 装 CLI / Desktop 后自动恢复
    case binaryNotFound
    /// CLI 版本太老、没有额度查询接口（JSON-RPC method not found）—— 升级后自动恢复
    case versionTooOld
    /// CLI 拒绝了 usageBar 的启动参数（Codex 新版改了命令行接口，如 0.149 删掉 `-a untrusted`）——
    /// 不会自愈、要升级 usageBar。与 `.network` 不同：store 不保留旧快照，别拿几天前的数字充数
    case cliIncompatible
    /// 工具**本身确认未登录**（`qodercli status -o json` 回 `logged_in:false`）——去登录即可恢复。
    /// 与 `.credentialUnavailable` 的区别：那个说的是「某个额度凭证不可用」（可能是别的产品的），
    /// 这个是对本工具登录态的**确凿判定**（v0.3.37）
    case notLoggedIn
    /// **已登录，但暂时没有额度数字**——不是错误，是中性等待态（v0.3.37）。
    /// 典型场景：Qoder CLI 登录正常，但本机没装 QoderWork / Qoder IDE，CLI 自己也还没跑出过额度日志。
    /// ⚠️ 这一档存在的意义就是不让它被压进 `.credentialUnavailable` ——
    /// 「我明明能用，你说我掉登录」是外部用户 2026-08-28 报的原始观感
    case quotaUnavailable
}
