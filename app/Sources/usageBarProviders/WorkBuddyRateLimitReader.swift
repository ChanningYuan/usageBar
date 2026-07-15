import Foundation
import usageBarCore

/// WorkBuddy（CodeBuddy，腾讯）账号额度读取（v0.3.24）——零弹窗。
///
/// 登录凭证是**明文 JSON**（不像 Qoder 加密），所以零钥匙串、零授权框：
/// `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info`
/// 里 `auth.accessToken` 是 JWT，调 `get-user-resource` 拿真实信用点余额。方案来自 jlcodes99/cockpit-tools。
///
/// 返回（实测）：`CapacitySize/CapacityRemain`（总额/剩余）+ `CycleStartTime/EndTime`（月度周期）+ `PackageName`（套餐）。
public struct WorkBuddyRateLimitReader {
    public init() {}

    public static let providerId = "workbuddy"
    private static let endpoint = "https://www.codebuddy.cn/v2/billing/meter/get-user-resource"

    private var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
    }

    public func read(now: Date = Date()) async -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }

        // 1. 读明文登录文件拿 accessToken（零弹窗）
        guard let data = try? Data(contentsOf: authFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = obj["auth"] as? [String: Any],
              let token = auth["accessToken"] as? String, !token.isEmpty else {
            return fail(.credentialUnavailable)
        }

        // 2. 调资源包接口
        guard let url = URL(string: Self.endpoint) else { return fail(.network) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("WorkBuddy", forHTTPHeaderField: "User-Agent")

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return fail(.network) }
            switch http.statusCode {
            case 200: break
            case 401, 403: return fail(.credentialUnavailable)
            default: return fail(.network)
            }
            guard let root = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let dataObj = root["data"] as? [String: Any],
                  let response = dataObj["Response"] as? [String: Any],
                  let inner = response["Data"] as? [String: Any] else {
                return fail(.network)
            }
            // 聚合所有资源包（可能多个）：本周期总额/剩余
            let accounts = (inner["Accounts"] as? [[String: Any]]) ?? []
            var cycleSize = 0.0, cycleRemain = 0.0
            var pkgName: String?
            var cycleEnd: Date?
            for acc in accounts {
                cycleSize += (acc["CycleCapacitySize"] as? NSNumber)?.doubleValue ?? 0
                cycleRemain += (acc["CycleCapacityRemain"] as? NSNumber)?.doubleValue ?? 0
                if pkgName == nil { pkgName = acc["PackageName"] as? String }
                if cycleEnd == nil, let s = acc["CycleEndTime"] as? String {
                    cycleEnd = Self.parseCycleTime(s)
                }
            }
            guard cycleSize > 0 else { return fail(.noQuotaData) }
            let used = cycleSize - cycleRemain
            let pct = cycleSize > 0 ? (used / cycleSize) * 100 : 0
            let win = RateLimitWindow(kind: "monthly", label: "月", usedPercent: pct,
                                      resetsAt: cycleEnd,
                                      detail: RateLimitWindow.usedOfTotal(used, cycleSize))
            return RateLimitSnapshot(providerId: Self.providerId, windows: [win],
                                     planType: pkgName, capturedAt: now, error: nil)
        } catch {
            return fail(.network)
        }
    }

    /// CycleEndTime 形如 "2026-07-31 23:59:59"（本地时区）
    private static func parseCycleTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: s)
    }
}
