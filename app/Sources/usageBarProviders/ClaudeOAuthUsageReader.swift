import Foundation
import Security
import usageBarCore

/// Claude Code 账号额度读取（v0.3.24）——走官方未文档化的 OAuth 接口。
///
/// `GET https://api.anthropic.com/api/oauth/usage`（CodexBar 同款主路径）。凭证不用用户填——
/// Claude Code 自己把 OAuth token 存在系统钥匙串 `Claude Code-credentials`，复用即可。
///
/// 三个坑（2026-07-14 探针实证，见 spec §4.2）：
/// 1. **UA 必须带 `claude-code/<版本>`**——不带会进激进限流桶、频繁 429。
/// 2. **绝不自己刷新 token**（避免和 Claude Code 抢刷新导致互相踢下线）：每次读钥匙串取最新；
///    401 → 落 credentialUnavailable，等用户下次用 claude 时它自己刷新。
/// 3. **首次读钥匙串弹系统授权框**：点拒绝 → authDenied，本会话内不再自动重试。
public struct ClaudeOAuthUsageReader {
    public init() {}

    public static let providerId = "claude-code"
    private static let keychainService = "Claude Code-credentials"
    private static let endpoint = "https://api.anthropic.com/api/oauth/usage"

    /// ⚠️ token 内存缓存（跨刷新复用）——**关键：不能每次刷新都读钥匙串**，否则每 10 分钟弹一次
    /// 系统授权框（尤其未签名的开发构建，"始终允许"记不住）。只在无缓存 / 401 时才读钥匙串。
    nonisolated(unsafe) private static var cachedToken: String?
    nonisolated(unsafe) private static var cachedPlan: String?

    /// 取消授权/重置时清缓存 → 下次读重新读钥匙串（重新授权）
    public static func clearCache() { cachedToken = nil; cachedPlan = nil }

    public func read(now: Date = Date()) async -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }

        // 1. 优先用缓存 token 请求（不碰钥匙串 → 不弹框）
        if let tok = Self.cachedToken {
            let snap = await request(token: tok, plan: Self.cachedPlan, now: now)
            if snap.error != .credentialUnavailable { return snap }
            Self.cachedToken = nil   // 401 → token 过期，清缓存，下面重读钥匙串
        }

        // 2. 读钥匙串拿新 token（会弹授权框；点「始终允许」后签名版不再弹）
        switch Self.readCredentials() {
        case .success(let c):
            Self.cachedToken = c.accessToken
            Self.cachedPlan = c.subscriptionType
            return await request(token: c.accessToken, plan: c.subscriptionType, now: now)
        case .denied:   return fail(.authDenied)
        case .notFound: return fail(.credentialUnavailable)
        }
    }

    private func request(token: String, plan: String?, now: Date) async -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }
        guard let url = URL(string: Self.endpoint) else { return fail(.network) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            let windows = Self.parseWindows(obj)
            if windows.isEmpty { return fail(.noQuotaData) }
            return RateLimitSnapshot(providerId: Self.providerId, windows: windows,
                                     planType: plan, capturedAt: now, error: nil)
        } catch {
            return fail(.network)
        }
    }

    // MARK: - 响应解析

    /// 优先用结构化的 `limits[]`（带 severity + scope）；退化到具名窗口 `five_hour`/`seven_day`。
    static func parseWindows(_ obj: [String: Any]) -> [RateLimitWindow] {
        if let limits = obj["limits"] as? [[String: Any]], !limits.isEmpty {
            var out: [RateLimitWindow] = []
            for lim in limits {
                guard let pct = (lim["percent"] as? NSNumber)?.doubleValue else { continue }
                let kind = lim["kind"] as? String ?? "unknown"
                let severity = lim["severity"] as? String
                let resets = (lim["resets_at"] as? String).flatMap(Self.parseISO)
                var scopeModel: String?
                if let scope = lim["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String {
                    scopeModel = name
                }
                let label = Self.label(kind: kind, scopeModel: scopeModel)
                out.append(RateLimitWindow(kind: kind, label: label, windowMinutes: nil,
                                           usedPercent: pct, resetsAt: resets,
                                           severity: severity, scopeModel: scopeModel))
            }
            if !out.isEmpty { return out }
        }
        // 兜底：具名窗口
        var out: [RateLimitWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let w = obj[key] as? [String: Any],
                  let pct = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resets = (w["resets_at"] as? String).flatMap(Self.parseISO)
            out.append(RateLimitWindow(kind: key, label: label, usedPercent: pct, resetsAt: resets))
        }
        return out
    }

    private static func label(kind: String, scopeModel: String?) -> String {
        if let m = scopeModel { return m }   // 分模型限额用模型名（Fable）
        switch kind {
        case "session": return "5h"
        case "weekly_all": return "7d"
        case "weekly_scoped": return scopeModel ?? "7d"
        default: return kind
        }
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    // MARK: - 钥匙串

    struct Credentials { let accessToken: String; let subscriptionType: String? }
    enum KeychainResult { case success(Credentials); case denied; case notFound }

    /// 读 `Claude Code-credentials` generic password 里的 `claudeAiOauth.accessToken` + `subscriptionType`。
    /// ⚠️ 首次调用会弹系统授权框。
    static func readCredentials() -> KeychainResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty
            else { return .notFound }
            let sub = oauth["subscriptionType"] as? String
            return .success(Credentials(accessToken: token, subscriptionType: sub))
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .notFound
        }
    }

    // MARK: - User-Agent

    /// `claude-code/<版本>`——版本从 `claude --version` 取一次并缓存，失败用兜底常量。
    static let userAgent: String = {
        let version = detectClaudeVersion() ?? "2.0.0"
        return "claude-code/\(version)"
    }()

    private static func detectClaudeVersion() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            // 形如 "2.1.0 (Claude Code)" → 抽第一个 x.y.z
            if let range = out.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                return String(out[range])
            }
        } catch { return nil }
        return nil
    }
}
