import Foundation
import SQLite3
import usageBarCore

/// Cursor 账号额度读取（v0.3.24）——复用 Cursor 本地登录凭证，联网查 cursor.com。
///
/// `GET https://cursor.com/api/usage-summary`（2026-07-14 探针实证，见 spec §1/§4.4）返回：
/// ```json
/// {"billingCycleEnd":"2026-08-06T...","membershipType":"pro_plus","isUnlimited":false,
///  "individualUsage":{"plan":{"totalPercentUsed":18.7,"apiPercentUsed":86.9}}}
/// ```
/// 映射成两个「月度窗口」：总用量 + 指定模型（API）用量，重置时间都是 `billingCycleEnd`。
///
/// 自包含（不改 `CursorProvider`）：自己读 `state.vscdb` 的 accessToken、解 JWT sub、发请求。
public struct CursorRateLimitReader {
    public init() {}

    public static let providerId = "cursor"

    private var stateDbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    public func read(now: Date = Date()) async -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }

        guard let token = readAccessToken(), let sub = jwtSub(token) else {
            return fail(.credentialUnavailable)
        }
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else { return fail(.network) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        // Cursor 该端点认 Cookie `WorkosCursorSessionToken=<sub>::<token>`（:: 需 URL 编码）
        req.setValue("WorkosCursorSessionToken=\(sub)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return fail(.network) }
            switch http.statusCode {
            case 200: break
            case 401, 403: return fail(.credentialUnavailable)
            default: return fail(.network)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return fail(.network)
            }
            let plan = obj["membershipType"] as? String
            if obj["isUnlimited"] as? Bool == true {
                return fail(.noQuotaData)   // 无限额度，没有百分比可显示
            }
            let resets = (obj["billingCycleEnd"] as? String).flatMap(Self.parseISO)
            guard let usage = obj["individualUsage"] as? [String: Any],
                  let planUsage = usage["plan"] as? [String: Any] else {
                return fail(.noQuotaData)
            }
            var windows: [RateLimitWindow] = []
            if let total = (planUsage["totalPercentUsed"] as? NSNumber)?.doubleValue {
                windows.append(RateLimitWindow(kind: "cursor_total", label: "月",
                                               usedPercent: total, resetsAt: resets))
            }
            if let api = (planUsage["apiPercentUsed"] as? NSNumber)?.doubleValue, api > 0 {
                windows.append(RateLimitWindow(kind: "cursor_api", label: "API",
                                               usedPercent: api, resetsAt: resets))
            }
            if windows.isEmpty { return fail(.noQuotaData) }
            return RateLimitSnapshot(providerId: Self.providerId, windows: windows,
                                     planType: plan, capturedAt: now, error: nil)
        } catch {
            return fail(.network)
        }
    }

    // MARK: - 本地凭证

    /// 读 state.vscdb 的 cursorAuth/accessToken（read-only，不干扰 Cursor）
    private func readAccessToken() -> String? {
        let uri = "file:\(stateDbPath)?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// JWT payload.sub 完整值（Cookie 需要完整 sub，不是去前缀的 userId）
    private func jwtSub(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = Self.base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String else { return nil }
        return sub
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: b64)
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
