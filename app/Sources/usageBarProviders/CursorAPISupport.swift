import Foundation

// MARK: - JWT 解析

/// 从 Cursor accessToken（JWT）里解出 userId（payload.sub 的最后一段）。
enum CursorJWT {
    static func userId(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payloadData = base64urlDecode(String(parts[1])) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else { return nil }
        guard let sub = obj["sub"] as? String else { return nil }
        // sub 形如 "auth0|user_01JHV..." 或直接 "user_01JHV..."，取最后一段
        return sub.split(separator: "|").last.map(String.init) ?? sub
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        // 补 padding
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: b64)
    }
}

// MARK: - 网络

enum CursorAPIError: Error {
    case badStatus(Int)
    case noData
}

/// 调 cursor.com 只读用量接口。
/// 只发 cursor.com 官方域名，只用 GET，绝不碰写接口。
enum CursorAPI {
    /// GET /api/dashboard/export-usage-events-csv?strategy=tokens
    /// 返回逐次对话的精确 token CSV。
    static func fetchUsageCSV(userId: String, token: String) async throws -> String {
        let url = URL(string: "https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 25
        // 会话 Cookie：WorkosCursorSessionToken=<userId>%3A%3A<jwt>
        let cookie = "WorkosCursorSessionToken=\(userId)%3A%3A\(token)"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.cursor.com/settings", forHTTPHeaderField: "Referer")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CursorAPIError.badStatus(http.statusCode)
        }
        guard let str = String(data: data, encoding: .utf8) else { throw CursorAPIError.noData }
        return str
    }
}

// MARK: - 用量事件模型

/// Cursor 一次对话的用量（来自 CSV 一行）。
struct CursorUsageEvent {
    let timestampISO: String   // CSV 的 Date 列（ISO 8601）
    let model: String
    let inputNoCache: Int      // Input (w/o Cache Write) → prompt_tokens
    let inputWithCache: Int    // Input (w/ Cache Write)  → cache_creation_input_tokens
    let cacheRead: Int         // Cache Read              → cache_read_input_tokens
    let output: Int            // Output Tokens           → completion_tokens
    let totalTokens: Int       // Total Tokens
    let cost: String           // Cost（原样保留字符串）

    /// 去重 key：**时间戳 + 模型**。
    ///
    /// ⚠️ v0.3.22 修复（用量虚高 +72%）：旧 key 是 `时间戳|totalTokens`，看着"足以唯一标识一次对话"，
    /// 实则**去重完全失效** —— Cursor 的用量事件是**累计快照**：一条对话进行中会被反复上报，
    /// **时间戳固定在对话开始那一刻，token 逐次累加**，服务端只保留终值。于是 `totalTokens` 每次都变
    /// → key 永远不重复 → 每一份中间快照都被当成新事件累加。
    ///
    /// 实测同一条对话（2026-07-13T08:08:46.812Z / claude-fable-5-thinking-high）在 mirror 里存了 4 份：
    /// `1,891,508 → 5,659,446 → 6,183,595 → 14,504,573`，真值只有终值 1450 万，却被加成 2824 万。
    /// 全量对账：显示 94,164,889 vs 真值 54,742,624（虚高 39,422,265，+72%）。
    ///
    /// 同类前科：Codex 峰值跟踪 —— **累计型数据被当成增量累加**。
    ///
    /// 去掉 token 后，同一条对话的多份快照落到同一个 key 上 → 由 `mergeIntoMirror` 取终值覆盖。
    var dedupeKey: String { "\(timestampISO)|\(model)" }

    /// 序列化成 mirror jsonl 一行（usageBar 统一 schema）
    func toJSONLine() -> String {
        let obj: [String: Any] = [
            "timestamp": timestampISO,
            "prompt_tokens": inputNoCache,
            "completion_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": inputWithCache,
            "total_tokens": totalTokens,
            "model": model,
            "cost": cost,
            "source": "cursor",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 从 mirror jsonl 一行还原 dedupeKey（时间戳 + 模型）。与 `dedupeKey` 必须同构。
    static func dedupeKey(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = obj["timestamp"] as? String else { return nil }
        let model = (obj["model"] as? String) ?? ""
        return "\(ts)|\(model)"
    }

    /// 从 mirror jsonl 一行取 total_tokens（同 key 取终值时比大小用）。
    static func totalTokens(fromJSONLine line: String) -> Int {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return (obj["total_tokens"] as? Int) ?? 0
    }
}

// MARK: - CSV 解析

/// 解析 export-usage-events-csv 的返回。
/// 列：Date, Cloud Agent ID, Automation ID, Kind, Model, Max Mode,
///     Input (w/ Cache Write), Input (w/o Cache Write), Cache Read, Output Tokens, Total Tokens, Cost
enum CursorCSV {
    static func parse(_ csv: String) -> [CursorUsageEvent] {
        var rows = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        guard rows.count >= 2 else { return [] }

        // 第一行是表头，定位各列索引（防列序变化）
        let header = parseLine(rows.removeFirst())
        func idx(_ name: String) -> Int? { header.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }

        let iDate = idx("Date")
        let iModel = idx("Model")
        let iInWith = idx("Input (w/ Cache Write)")
        let iInNo = idx("Input (w/o Cache Write)")
        let iCacheRead = idx("Cache Read")
        let iOutput = idx("Output Tokens")
        let iTotal = idx("Total Tokens")
        let iCost = idx("Cost")

        var events: [CursorUsageEvent] = []
        for row in rows {
            let cols = parseLine(row)
            guard !cols.isEmpty else { continue }
            func col(_ i: Int?) -> String { (i.flatMap { $0 < cols.count ? cols[$0] : nil }) ?? "" }
            func num(_ i: Int?) -> Int { Int(col(i).trimmingCharacters(in: .whitespaces)) ?? 0 }

            let dateStr = col(iDate)
            if dateStr.isEmpty { continue }
            events.append(CursorUsageEvent(
                timestampISO: dateStr,
                model: col(iModel),
                inputNoCache: num(iInNo),
                inputWithCache: num(iInWith),
                cacheRead: num(iCacheRead),
                output: num(iOutput),
                totalTokens: num(iTotal),
                cost: col(iCost)
            ))
        }
        return events
    }

    /// 解析一行 CSV，处理双引号包裹的字段。
    private static func parseLine(_ line: String) -> [String] {
        var result: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\""); i += 1   // 转义的双引号
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    result.append(field); field = ""
                } else {
                    field.append(c)
                }
            }
            i += 1
        }
        result.append(field)
        return result
    }
}
