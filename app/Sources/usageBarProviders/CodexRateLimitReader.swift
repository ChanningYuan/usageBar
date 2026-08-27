import Foundation
import usageBarCore

/// Codex 账号额度读取（v0.3.31 起走官方 RPC，0812 spec；v0.3.24–v0.3.30 的 JSONL 扫描已退役）。
///
/// 为什么退役 JSONL：rollout 日志可达 15–248MB，主池记录被挤出尾窗（issue #7）；`limit_id`
/// 语义两个版本内漂了三次，「按模型共现猜池」的启发式会**显示错数据**（issue #6/#7 连环回归）。
/// 错数据比"诚实说读不到"伤害大。现在数据源 = `codex app-server` 的 `account/rateLimits/read`：
/// 官方按池分好（`rateLimitsByLimitId`），带套餐/积分/企业管控/重置券全量字段，与文件布局无关。
///
/// 失败语义（0812 spec §三.3）：
/// - 断网/超时/进程失败 → `.network`（RateLimitStore 保留上次快照，UI 显示「更新于 Xh 前 · 连接不上 Codex」）
/// - 发现链全空 → `.binaryNotFound`；版本太老无此方法 → `.versionTooOld`
/// - 未登录 → `.credentialUnavailable`；API Key 登录 → `.noQuotaData`
/// - 启动参数被 CLI 拒绝（新版删了旧参数，2026-08-24 Codex 0.149 实踩）→ `.cliIncompatible`（不自愈，提示升级 usageBar）
///
/// ⚠️ token 用量统计与本文件无关（CodexDetailScanner 继续读 JSONL——那是纯累加，无猜池问题）。
public struct CodexRateLimitReader {
    public init() {}

    public static let providerId = "codex"

    public func read(now: Date = Date()) async -> RateLimitSnapshot {
        let fetched = await Task.detached(priority: .utility) {
            CodexAppServerClient.fetch()
        }.value

        switch fetched {
        case .success(let r):
            if r.accountType == "apikey" {
                return Self.fail(.noQuotaData, now: now)
            }
            let snap = Self.snapshot(fromRPC: r.rateLimits, accountPlan: r.accountPlan, now: now)
            return snap.windows.isEmpty ? Self.fail(.noQuotaData, now: now) : snap
        case .failure(let e):
            switch e {
            case .binaryNotFound: return Self.fail(.binaryNotFound, now: now)
            case .methodNotFound: return Self.fail(.versionTooOld, now: now)
            case .notLoggedIn:    return Self.fail(.credentialUnavailable, now: now)
            case .timeout, .processFailed:
                return Self.fail(.network, now: now)
            case .incompatibleCLI: return Self.fail(.cliIncompatible, now: now)
            }
        }
    }

    static func fail(_ e: RateLimitError, now: Date) -> RateLimitSnapshot {
        RateLimitSnapshot(providerId: providerId, windows: [], capturedAt: now, error: e)
    }

    // MARK: - RPC result 解析（纯函数，fixture 可测）

    /// `account/rateLimits/read` 的 result → 快照。
    /// 字段名是 RPC 侧 camelCase（`windowDurationMins` / `resetsAt` 秒级时间戳）。
    static func snapshot(fromRPC result: [String: Any], accountPlan: String?,
                         now: Date) -> RateLimitSnapshot {
        // 1. 池集合：优先 rateLimitsByLimitId（按池分好）；老版本只有单条 rateLimits 也收
        var pools: [[String: Any]] = []
        if let byId = result["rateLimitsByLimitId"] as? [String: [String: Any]], !byId.isEmpty {
            pools = Array(byId.values)
        } else if let single = result["rateLimits"] as? [String: Any] {
            pools = [single]
        }

        // 2. 主池 = limitId=="codex" 优先，否则第一个无名池；其余全按专属池呈现
        func limitId(_ p: [String: Any]) -> String { (p["limitId"] as? String) ?? "codex" }
        func limitName(_ p: [String: Any]) -> String? { p["limitName"] as? String }
        let mainIdx = pools.firstIndex { limitId($0) == "codex" }
            ?? pools.firstIndex { limitName($0) == nil }
        // 稳定排序：主池第一，专属池按 limitId 字典序
        var ordered: [[String: Any]] = []
        if let m = mainIdx { ordered.append(pools[m]) }
        ordered.append(contentsOf: pools.enumerated()
            .filter { $0.offset != mainIdx }
            .map(\.element)
            .sorted { limitId($0) < limitId($1) })

        var windows: [RateLimitWindow] = []
        for (i, pool) in ordered.enumerated() {
            let isMain = (i == 0 && mainIdx != nil)
            let base = Self.poolWindows(pool)
            if isMain {
                windows.append(contentsOf: base)
            } else {
                // 专属池：limit_name 短名当 label（"GPT-5.3-Codex-Spark"→"Spark"），
                // 单窗口不带 5h/7d（同 Claude Fable chip）；kind 前缀 codex_scoped
                let short = Self.nameShort(limitName(pool) ?? limitId(pool))
                windows.append(contentsOf: base.map { w in
                    RateLimitWindow(kind: w.kind.replacingOccurrences(of: "codex", with: "codex_scoped"),
                                    label: base.count > 1 ? "\(short) \(w.label)" : short,
                                    windowMinutes: w.windowMinutes, usedPercent: w.usedPercent,
                                    resetsAt: w.resetsAt, severity: w.severity, scopeModel: short)
                })
            }
        }

        // 3. 账号级字段：主池优先，任意池兜底
        func firstValue<T>(_ key: String, as type: T.Type) -> T? {
            for p in ordered { if let v = p[key] as? T { return v } }
            return nil
        }
        let plan = firstValue("planType", as: String.self) ?? accountPlan
        var credits: RateLimitCredits?
        if let c = firstValue("credits", as: [String: Any].self) {
            credits = RateLimitCredits(hasCredits: (c["hasCredits"] as? Bool) ?? false,
                                       unlimited: (c["unlimited"] as? Bool) ?? false,
                                       balance: Self.stringy(c["balance"]))
        }
        var spendCap: RateLimitSpendCap?
        if let l = firstValue("individualLimit", as: [String: Any].self),
           let limit = Self.stringy(l["limit"]), let used = Self.stringy(l["used"]) {
            spendCap = RateLimitSpendCap(limit: limit, used: used,
                                         remainingPercent: (l["remainingPercent"] as? NSNumber)?.doubleValue,
                                         resetsAt: Self.epochDate(l["resetsAt"]))
        }
        let spendReached = firstValue("spendControlReached", as: Bool.self)
        let reachedType = firstValue("rateLimitReachedType", as: String.self)

        // 4. 重置券
        var coupons: [RateLimitResetCoupon]?
        if let rc = result["rateLimitResetCredits"] as? [String: Any],
           let list = rc["credits"] as? [[String: Any]] {
            coupons = list.map {
                RateLimitResetCoupon(title: $0["title"] as? String,
                                     status: ($0["status"] as? String) ?? "unknown",
                                     expiresAt: Self.epochDate($0["expiresAt"]))
            }
        }

        return RateLimitSnapshot(providerId: providerId, windows: windows, planType: plan,
                                 capturedAt: now, error: nil,
                                 credits: credits, spendCap: spendCap,
                                 spendControlReached: spendReached,
                                 rateLimitReachedType: reachedType,
                                 resetCoupons: coupons)
    }

    /// 单池的 primary / secondary → 窗口（label 一律由 windowDurationMins 推导，铁律不变）
    static func poolWindows(_ pool: [String: Any]) -> [RateLimitWindow] {
        var out: [RateLimitWindow] = []
        for (key, kind) in [("primary", "codex_primary"), ("secondary", "codex_secondary")] {
            guard let w = pool[key] as? [String: Any],
                  let pct = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue
            let label = minutes.map { RateLimitWindow.label(forWindowMinutes: $0) } ?? key
            out.append(RateLimitWindow(kind: kind, label: label, windowMinutes: minutes,
                                       usedPercent: pct, resetsAt: Self.epochDate(w["resetsAt"])))
        }
        return out
    }

    /// 展示短名：取 `-` 分隔的最后一段并首字母大写（"GPT-5.3-Codex-Spark" → "Spark"）。
    static func nameShort(_ name: String) -> String {
        guard let last = name.split(separator: "-").last, !last.isEmpty else { return name }
        return String(last).prefix(1).uppercased() + String(last).dropFirst()
    }

    /// 官方数值字段守形：字符串原样、数字转字符串（balance / limit / used 都是美元字符串，但守着点）
    static func stringy(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// 秒级 epoch（Int/Double）或 ISO8601 字符串 → Date
    static func epochDate(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        return nil
    }
}
