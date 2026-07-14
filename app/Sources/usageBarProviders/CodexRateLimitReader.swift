import Foundation
import usageBarCore

/// Codex 账号额度读取（v0.3.24）——纯本地，零联网、零成本。
///
/// 数据源：`~/.codex/sessions/**/rollout-*.jsonl` 里 `payload.type=="token_count"` 事件的 `rate_limits` 字段。
/// 取 mtime 最新的文件、从尾部往前找最后一条带 `rate_limits` 的事件即可（额度是账号全局状态，不用扫全部历史）。
///
/// ⚠️ 窗口结构是动态的（2026-07-14 探针实证，见 spec §1c）：
/// ```json
/// "rate_limits":{"primary":{"used_percent":21,"window_minutes":10080,"resets_at":...},"secondary":null,...}
/// ```
/// primary 可能是 5 小时窗也可能是 7 天窗（看 `window_minutes`），secondary 可能为 null。
/// **按 window_minutes 推导 label，有几个窗口画几个，别写死 5h+7d。**
public struct CodexRateLimitReader {
    public init() {}

    private var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    public static let providerId = "codex"

    public func read(now: Date = Date()) -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return fail(.noDataSource)
        }
        // 取 mtime 最新的 rollout 文件（额度是账号级全局状态，只要最新一条）
        let files = JSONLReader.findFiles(under: sessionsDir) { url in
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        }
        let sorted = files.compactMap { url -> (URL, Date)? in
            guard let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return nil }
            return (url, m)
        }.sorted { $0.1 > $1.1 }

        guard !sorted.isEmpty else { return fail(.noDataSource) }

        // 从最新几个文件里找最后一条 rate_limits（纯 API Key 登录可能没有这个字段）
        for (url, _) in sorted.prefix(5) {
            if let rl = lastRateLimits(in: url) {
                let windows = Self.parseWindows(rl)
                if windows.isEmpty { continue }
                let plan = rl["plan_type"] as? String
                return RateLimitSnapshot(providerId: Self.providerId, windows: windows,
                                         planType: plan, capturedAt: now, error: nil)
            }
        }
        // 有文件但没有 rate_limits 字段 → 纯 API Key 登录，无额度概念
        return fail(.noQuotaData)
    }

    /// 从文件尾部往前找最后一条带 `rate_limits` 的 token_count 事件（只读尾部，不整份 parse）。
    private func lastRateLimits(in url: URL) -> [String: Any]? {
        guard let tail = Self.readTail(url, maxBytes: 256 * 1024) else { return nil }
        // 逐行从后往前
        let lines = tail.split(separator: "\n").reversed()
        for line in lines {
            guard line.contains("rate_limits"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            if payload["type"] as? String == "token_count",
               let rl = payload["rate_limits"] as? [String: Any] {
                return rl
            }
        }
        return nil
    }

    /// primary / secondary 各自按 window_minutes 推导，null 的跳过。
    static func parseWindows(_ rl: [String: Any]) -> [RateLimitWindow] {
        var out: [RateLimitWindow] = []
        for (key, kind) in [("primary", "codex_primary"), ("secondary", "codex_secondary")] {
            guard let w = rl[key] as? [String: Any],
                  let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let label = minutes.map { RateLimitWindow.label(forWindowMinutes: $0) } ?? key
            out.append(RateLimitWindow(kind: kind, label: label, windowMinutes: minutes,
                                       usedPercent: pct, resetsAt: resets))
        }
        return out
    }

    /// 读文件尾部最多 maxBytes 字节（macOS 无 tac，用 FileHandle seek）
    static func readTail(_ url: URL, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
