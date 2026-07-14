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
    /// 附注，如 "1,234 / 5,000 Credits"（Qoder 月配额用）
    public let detail: String?

    public init(kind: String, label: String, windowMinutes: Int? = nil, usedPercent: Double,
                resetsAt: Date? = nil, severity: String? = nil, scopeModel: String? = nil,
                detail: String? = nil) {
        self.kind = kind
        self.label = label
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.severity = severity
        self.scopeModel = scopeModel
        self.detail = detail
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

/// 某 provider 某次采集时刻的完整额度快照
public struct RateLimitSnapshot: Codable, Sendable, Equatable {
    public let providerId: String
    /// ⚠️ 数量动态：可能 1 条也可能 3 条
    public let windows: [RateLimitWindow]
    /// 套餐名："max" / "prolite" / "Community" / "pro_plus"…，仅作展示
    public let planType: String?
    /// 本次采集时刻（本地时钟）
    public let capturedAt: Date
    /// 采集失败原因（超时/未登录/凭证失效/无配额数据/无数据源）；非 nil 时 windows 可能为空
    public let error: RateLimitError?

    public init(providerId: String, windows: [RateLimitWindow], planType: String? = nil,
                capturedAt: Date, error: RateLimitError? = nil) {
        self.providerId = providerId
        self.windows = windows
        self.planType = planType
        self.capturedAt = capturedAt
        self.error = error
    }

    /// 「最紧窗口」= usedPercent 最高的那个（主列表药丸只显示这一个的场景可能会用；本版药丸子行全显）。
    public var tightestWindow: RateLimitWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// 复制成另一个 providerId（Qoder 一次 read → 复制到 CLI/Work/IDE 三实例）
    public func with(providerId newId: String) -> RateLimitSnapshot {
        RateLimitSnapshot(providerId: newId, windows: windows, planType: planType,
                          capturedAt: capturedAt, error: error)
    }
}

/// 采集失败的分类（对应 spec §2.5 状态机的错误态）
public enum RateLimitError: String, Codable, Sendable, Equatable {
    /// 凭证读不到 / 钥匙串拒绝 / 401 过期 —— 用户「用一次工具后自动恢复」或点重试
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
}
