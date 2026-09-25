import CryptoKit
import Foundation

// MARK: - 豆包工作 · 接口层（v0.3.45）
//
// 数据源实测记录：知识库 `docs/0906-豆包接入/豆包接入-spec.md` §3、`豆包工作-token与场景调研.md`。
// 两个接口，都是 `POST https://www.doubao.com…`，登录态 = DoubaoWork 自带 Chromium 壳里 doubao.com 的 cookie：
// - `subscription/overview`：两档额度窗口（当前时段 5 小时 / 近 7 天）+ 套餐 + 活动权益到期。
//   窗口与 `quota/summary` 逐字段相同（2026-09-24 实测），但只有 overview 带活动权益到期——
//   App 里「免费体验至 10月25日」显示的就是它，订阅记录本身的到期是本期结束（09-25）；
// - `usage/timeline`（category=3）：逐笔积分消耗，服务端只展示近 30 天。
//
// ⛔ **豆包工作不向客户端提供 token 消耗数**（2026-09-24 带调试口实抓回复流定案）：回复流里只有上下文窗口
// 快照，「消耗 x」是长连接推送的积分展示串。所以这里只有积分，token 一律 0、界面显示「—」。

/// 一个额度窗口（`window_limits[]` 的一项）。
public struct DoubaoWorkWindow: Codable, Sendable, Equatable {
    /// 1 = 当前时段（5 小时），2 = 近 7 天
    public let type: Int
    /// 已用 / 总额的**展示串**，原样保留："<1"、"17"、"2,100"。
    /// 已用串缺失 = aid 不对（消费版的 aid 拿不到数字），不是 0。
    public let usedText: String?
    public let totalText: String?
    /// 整数百分比；小额消耗恒 0，配合 `lessThanOnePercent` 区分「没用」和「不到 1%」
    public let usedPercent: Int
    public let lessThanOnePercent: Bool
    /// 重置时刻。nil = 当前时段还没开始计时（往前 5 小时没用过，App 显示「开始使用后计时」）。
    /// ⚠️ 只照抄它，**别用起点 + 时长自己推算**——用户确认 7 天窗口「每 7 天固定重置」，单次样本的起止反推不出规则。
    public let endTime: Date?

    public init(type: Int, usedText: String?, totalText: String?, usedPercent: Int,
                lessThanOnePercent: Bool, endTime: Date?) {
        self.type = type
        self.usedText = usedText
        self.totalText = totalText
        self.usedPercent = usedPercent
        self.lessThanOnePercent = lessThanOnePercent
        self.endTime = endTime
    }

    /// 总额数值（剥千分位）。
    public var total: Double? { totalText.flatMap(DoubaoWorkAPI.number) }
    /// 已用数值；`<1` 取上界 1（只给额度历史记录做变化判断，展示一律用原串）。
    public var used: Double? { usedText.flatMap(DoubaoWorkAPI.number) }
}

/// 套餐里展示用得上的三项。
public struct DoubaoWorkPlan: Codable, Sendable, Equatable {
    /// 套餐简称（「标准套餐」）
    public let name: String?
    /// 活动赠送的免费体验
    public let isGift: Bool
    /// 给用户看的到期：活动权益到期（`campaign_benefit_info.benefit_end_time`）优先，否则订阅本期结束。
    /// 与 App「免费体验至 x」一致（验收时实拍 App 写 10月25日，订阅记录的 end_time 却是 09-25）。
    public let endTime: Date?

    public init(name: String?, isGift: Bool, endTime: Date?) {
        self.name = name
        self.isGift = isGift
        self.endTime = endTime
    }
}

public struct DoubaoWorkQuota: Codable, Sendable, Equatable {
    /// 按 `type` 升序（当前时段在前）
    public let windows: [DoubaoWorkWindow]
    public let plan: DoubaoWorkPlan?
    /// 账号的单向哈希（取自 `merchant_user_id`），只用于判断换号；原始 id 不落盘
    public let accountHash: String?

    public init(windows: [DoubaoWorkWindow], plan: DoubaoWorkPlan?, accountHash: String?) {
        self.windows = windows
        self.plan = plan
        self.accountHash = accountHash
    }
}

/// 一笔积分消耗（`usage/timeline` 里 `entry_type == 1` 的一行）。
public struct DoubaoWorkUsageItem: Codable, Sendable, Equatable {
    /// 稳定唯一键：`D1#{用户id}#{Q:消息id}`。本地账本按它去重。
    public let itemId: String
    /// 消耗场景 = 会话标题（用户首条消息）。明细里**没有会话 id**，按会话分组只能靠它。
    public let title: String
    /// 模型展示名（Auto / 豆包 2.1 Turbo）。是展示名不是模型 id，价目表查不到——也不需要，积分是数据自带的。
    public let model: String
    public let occurredAt: Date
    /// 积分数值（两位小数）；`<0.01` 按上界 0.01 记，见 `DoubaoWorkAPI.credits`
    public let credits: Double
    /// 服务端展示串原样（"0.54" / "<0.01"）
    public let creditsText: String
    /// 额度来源展示名（豆包订阅）
    public let source: String

    public init(itemId: String, title: String, model: String, occurredAt: Date,
                credits: Double, creditsText: String, source: String) {
        self.itemId = itemId
        self.title = title
        self.model = model
        self.occurredAt = occurredAt
        self.credits = credits
        self.creditsText = creditsText
        self.source = source
    }
}

public struct DoubaoWorkTimelinePage: Sendable, Equatable {
    public let items: [DoubaoWorkUsageItem]
    public let hasMore: Bool
    public let nextCursor: String?
    /// 本页最早一行的时间（含「7天重置」分隔行），增量翻页判停用
    public let oldest: Date?
}

public enum DoubaoWorkAPI {
    static let host = "https://www.doubao.com"
    static let overviewPath = "/alice/commerce/sale/subscription/overview/"
    static let timelinePath = "/alice/commerce/usage/timeline/"
    /// 豆包工作的 app id。⚠️ 它决定能不能拿到额度数字：不带它，窗口里没有已用 / 总额（2026-09-24 实测）。
    static let aid = "1044603"
    /// 业务码「登录已过期，请重新登录」。HTTP 仍是 200——不带 cookie、cookie 失效都回它（2026-09-24 实测）。
    static let loginExpiredCode = 710012001
    /// 明细每页条数。⚠️ 上限就是 50：传 100 / 200 会**静默返回空**、code 仍为 0（spec §3i）。
    static let pageSize = 50

    /// 豆包工作网页版的「订阅与额度管理」页（登录失效时给用户一个去处）
    public static let quotaPageURL = URL(string: "https://www.doubao.com/member/quota-management")!

    enum Response: Sendable, Equatable {
        case ok(Data)
        case loggedOut
        case failure
    }

    // MARK: 请求

    /// 查询参数。2026-09-24 实测只有 `aid` 是必需的（其余全删也 200、照样有数），
    /// 这里仍按豆包工作自己的请求带上常规参数，贴近 App 本身的请求形状。
    /// 刻意**不带** `msToken` / `a_bogus`（防刷令牌与请求签名，属于凭据，且实测不需要）。
    struct RequestContext: Sendable, Equatable {
        let appVersion: String?
        let chromiumVersion: String?
        let deviceId: String?

        /// 从本机豆包工作读：版本号（Info.plist）、Chromium 版本（框架目录名）、设备编号（`Local State` 的
        /// `aha.device.device_id`，普通 JSON，读它不需要任何授权）。读不到就不带，不影响结果。
        static func current(appURL: URL? = DoubaoWorkEnv.appURL,
                            dataDirectory: URL = DoubaoWorkEnv.dataDirectory) -> RequestContext {
            var version: String?
            var chromium: String?
            if let appURL {
                let plist = appURL.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: plist),
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    version = dict["CFBundleShortVersionString"] as? String
                }
                let versions = appURL.appendingPathComponent(
                    "Contents/Helpers/DoubaoWork Browser.app/Contents/Frameworks/DoubaoWork Browser Framework.framework/Versions")
                chromium = (try? FileManager.default.contentsOfDirectory(atPath: versions.path))?
                    .filter { $0.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
                    .max { $0.compare($1, options: .numeric) == .orderedAscending }
            }
            return RequestContext(appVersion: version, chromiumVersion: chromium,
                                  deviceId: deviceId(localState: dataDirectory.appendingPathComponent("Local State")))
        }

        static func deviceId(localState: URL) -> String? {
            guard let data = try? Data(contentsOf: localState),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let device = (root["aha"] as? [String: Any])?["device"] as? [String: Any]
            else { return nil }
            if let s = device["device_id"] as? String, !s.isEmpty { return s }
            if let n = device["device_id"] as? NSNumber { return n.stringValue }
            return nil
        }

        var queryItems: [URLQueryItem] {
            var items: [URLQueryItem] = [
                .init(name: "version_code", value: "20800"),
                .init(name: "language", value: "zh"),
                .init(name: "device_platform", value: "web"),
                .init(name: "doubao_device_platform", value: "desktop"),
                .init(name: "aid", value: DoubaoWorkAPI.aid),
                .init(name: "real_aid", value: DoubaoWorkAPI.aid),
                .init(name: "pkg_type", value: "release_version"),
                .init(name: "samantha_web", value: "1"),
                .init(name: "web_platform", value: "desktop"),
                .init(name: "use-olympus-account", value: "1"),
                .init(name: "runtime", value: "web"),
                .init(name: "client_platform", value: "pc_client"),
                .init(name: "channel", value: "mac_official"),
            ]
            if let appVersion {
                items.append(.init(name: "pc_version", value: appVersion))
                items.append(.init(name: "doubao_pc_version", value: appVersion))
            }
            if let chromiumVersion { items.append(.init(name: "chromium_version", value: chromiumVersion)) }
            if let deviceId {
                items.append(.init(name: "device_id", value: deviceId))
                items.append(.init(name: "tea_uuid", value: deviceId))
                items.append(.init(name: "fp", value: "verify_" + deviceId))
            }
            return items
        }
    }

    static func request(path: String, body: Data, cookie: String, context: RequestContext) -> URLRequest? {
        guard var components = URLComponents(string: host + path) else { return nil }
        components.queryItems = context.queryItems
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.httpBody = body
        // cookie 由我们自己拼进头里：关掉 URLSession 的 cookie 罐，别把响应的 Set-Cookie 存进 usageBar，
        // 也别把 usageBar 自己的 cookie 混进来
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("usageBar", forHTTPHeaderField: "User-Agent")
        return req
    }

    static func fetchQuota(cookie: String, context: RequestContext) async -> Response {
        return await post(request(path: overviewPath, body: Data("{}".utf8), cookie: cookie, context: context))
    }

    static func fetchTimeline(cursor: String, cookie: String, context: RequestContext) async -> Response {
        let payload: [String: Any] = ["category": 3, "cursor": cursor, "page_size": pageSize]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .failure }
        return await post(request(path: timelinePath, body: body, cookie: cookie, context: context))
    }

    private static func post(_ request: URLRequest?) async -> Response {
        guard let request else { return .failure }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure }
            return classify(status: http.statusCode, data: data)
        } catch {
            return .failure
        }
    }

    /// HTTP 401/403 或业务码 710012001 = 登录失效；code 0 = 成功；其余一律当暂时失败（保留旧数据）。
    static func classify(status: Int, data: Data) -> Response {
        if status == 401 || status == 403 { return .loggedOut }
        guard status == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .failure }
        switch (root["code"] as? NSNumber)?.intValue {
        case 0?, nil: return root["data"] is [String: Any] ? .ok(data) : .failure
        case loginExpiredCode?: return .loggedOut
        default: return .failure
        }
    }

    // MARK: 解析

    static func dataObject(_ data: Data) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any]
    }

    static func parseQuota(_ data: Data) -> DoubaoWorkQuota? {
        guard let root = dataObject(data) else { return nil }
        let groups = ((root["window_limit_section"] as? [String: Any])?["window_limit_groups"] as? [[String: Any]]) ?? []
        // 目前只见过 feature_group = general 一组；将来多组时优先通用组，别写死只认它
        let group = groups.first { ($0["feature_group"] as? String) == "general" } ?? groups.first
        let windows = ((group?["window_limits"] as? [[String: Any]]) ?? []).compactMap { w -> DoubaoWorkWindow? in
            guard let type = (w["window_type"] as? NSNumber)?.intValue else { return nil }
            return DoubaoWorkWindow(
                type: type,
                usedText: text(w["used_amount"]),
                totalText: text(w["total_amount"]),
                usedPercent: (w["used_percent"] as? NSNumber)?.intValue ?? 0,
                lessThanOnePercent: (w["less_than_one_percent"] as? Bool) ?? false,
                endTime: date(ms: w["end_time"]))
        }.sorted { $0.type < $1.type }

        var plan: DoubaoWorkPlan?
        var account: String?
        if let sub = root["current_subscription"] as? [String: Any], !sub.isEmpty {
            let display = sub["display"] as? [String: Any]
            let name = (display?["short_name"] as? String).flatMap(nonEmpty)
                ?? (display?["product_name"] as? String).flatMap(nonEmpty)
            let benefitEnd = date(ms: (root["campaign_benefit_info"] as? [String: Any])?["benefit_end_time"])
            plan = DoubaoWorkPlan(name: name, isGift: (sub["is_gift"] as? Bool) ?? false,
                                  endTime: benefitEnd ?? date(ms: sub["end_time"]))
            account = text(sub["merchant_user_id"]).map(accountHash)
        }
        return DoubaoWorkQuota(windows: windows, plan: plan, accountHash: account)
    }

    static func parseTimeline(_ data: Data) -> DoubaoWorkTimelinePage? {
        guard let root = dataObject(data) else { return nil }
        let entries = (root["entries"] as? [[String: Any]]) ?? []
        var items: [DoubaoWorkUsageItem] = []
        var oldest: Date?
        for entry in entries {
            // entry_type = 2 是「7天重置」分隔行，**没有** usage 字段——不分流直接取会崩（spec §3e 踩过）
            let when = date(ms: (entry["usage"] as? [String: Any])?["occurred_at_ms"])
                ?? date(ms: (entry["reset"] as? [String: Any])?["occurred_at_ms"])
            if let when { oldest = min(oldest ?? when, when) }
            guard (entry["entry_type"] as? NSNumber)?.intValue == 1,
                  let usage = entry["usage"] as? [String: Any],
                  let itemId = text(usage["item_id"]),
                  let occurredAt = date(ms: usage["occurred_at_ms"]),
                  let source = usage["quota_source"] as? [String: Any],
                  let creditsText = text(source["display_text"]),
                  let value = Self.credits(creditsText)
            else { continue }
            items.append(DoubaoWorkUsageItem(
                itemId: itemId,
                title: text(usage["display_name"]) ?? "(无标题会话)",
                model: text(usage["model_display_name"]) ?? "(未知模型)",
                occurredAt: occurredAt,
                credits: value,
                creditsText: creditsText,
                source: text(source["display_name"]) ?? ""))
        }
        return DoubaoWorkTimelinePage(
            items: items,
            hasMore: (root["has_more"] as? Bool) ?? false,
            nextCursor: text(root["next_cursor"]),
            oldest: oldest)
    }

    /// 积分展示串 → 数值。"0.54" → 0.54；"1,234.5" → 1234.5；
    /// "<0.01"（任务刚开始、消耗还没到一分）→ **按上界 0.01 记**：最多高估 0.01，
    /// 但不会让一个确实花了积分的会话显示成 0（那会被读成「没花钱」）。
    static func credits(_ text: String) -> Double? {
        number(text)
    }

    /// 服务端展示串 → 数值：剥千分位、`<x` 取上界 x。解析不了返回 nil（不编数）。
    static func number(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        if s.hasPrefix("<") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard let v = Double(s), v.isFinite, v >= 0 else { return nil }
        return v
    }

    static func accountHash(_ id: String) -> String {
        SHA256.hash(data: Data("doubao-work|\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func text(_ value: Any?) -> String? {
        if let s = value as? String { return nonEmpty(s) }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 毫秒时间戳 → Date；0 / 缺失 → nil（当前时段没开始计时时 start/end 都是 0）。
    private static func date(ms value: Any?) -> Date? {
        guard let n = value as? NSNumber, n.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
}
