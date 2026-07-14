import Foundation
import usageBarCore

/// Claude 额度读取 · statusline 搭便车（v0.3.24，**推荐路线：零弹窗、零起进程**）。
///
/// 原理：Claude Code 运行时把含 `rate_limits` 的 JSON 通过 stdin 喂给 `~/.claude/statusline.sh`。
/// 引导时 usageBar 往 statusline.sh 注入一行 `… | jq .rate_limits > ~/.claude/usagebar-quota.json`，
/// Claude 每刷新状态栏就顺手把额度写到这个文件。usageBar 只读这个文件 —— 不读钥匙串、不请求 API、不起进程。
///
/// 短板：只在用户开着 Claude 会话时更新（statusline 才被调用）；文件 mtime 作 capturedAt，据此判陈旧。
public struct ClaudeStatuslineReader {
    public init() {}

    public static let providerId = "claude-code"

    /// statusline 写额度的文件（引导时注入的写命令目标）
    public static var quotaFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/usagebar-quota.json")
    }

    public func read(now: Date = Date()) -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }
        let file = Self.quotaFile
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 文件不存在 = statusline 已注入但 Claude 还没刷新状态栏写入 → 等待态（不是凭证问题）
            return fail(.awaitingData)
        }
        // 文件 mtime = Claude 上次写额度的时刻 → 陈旧判定用它
        let captured = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date ?? now

        let windows = Self.parseRateLimits(obj)
        if windows.isEmpty { return fail(.noQuotaData) }
        return RateLimitSnapshot(providerId: Self.providerId, windows: windows,
                                 planType: nil, capturedAt: captured, error: nil)
    }

    /// 解析 `.rate_limits` 对象：`five_hour`/`seven_day`（+ 可能的分模型 `seven_day_*`）。
    static func parseRateLimits(_ obj: [String: Any]) -> [RateLimitWindow] {
        var out: [RateLimitWindow] = []
        func win(_ key: String, _ label: String, scope: String? = nil) {
            guard let w = obj[key] as? [String: Any] else { return }
            // 字段名两种写法都兜：used_percentage / utilization
            let pct = (w["used_percentage"] as? NSNumber)?.doubleValue
                ?? (w["utilization"] as? NSNumber)?.doubleValue
            guard let pct else { return }
            let resets = Self.parseResets(w["resets_at"])
            out.append(RateLimitWindow(kind: key, label: label, usedPercent: pct,
                                       resetsAt: resets, scopeModel: scope))
        }
        win("five_hour", "5h")
        win("seven_day", "7d")
        // 分模型（若 statusline 数据带）：seven_day_opus / seven_day_sonnet / seven_day_<model>
        for (k, v) in obj {
            guard k.hasPrefix("seven_day_"), v is [String: Any] else { continue }
            let model = String(k.dropFirst("seven_day_".count)).capitalized
            win(k, model, scope: model)
        }
        return out
    }

    /// resets_at 可能是 unix 秒（statusline 场景）或 ISO 字符串
    static func parseResets(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}
