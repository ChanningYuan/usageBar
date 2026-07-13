import Foundation
import SQLite3
import usageBarCore

/// Cursor provider（API 路线 + 本地 mirror）
///
/// ⚠️ usageBar 首个**联网** provider。原因：Cursor 本地 `state.vscdb` 的 `bubbleId.tokenCount`
/// 全是 0（官方承认 best-effort 不可靠），真实计费 token 只在 Cursor 服务端。
///
/// 数据流：
///   1. 读本地 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
///      的 `ItemTable.cursorAuth/accessToken`（JWT，纯本地，不联网）
///   2. 解 JWT payload.sub → userId，拼会话 Cookie
///   3. GET `cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens`（逐次事件）
///   4. 解析 CSV，增量 mirror 到 `~/Library/Application Support/usageBar/cursor-usage-capture.jsonl`
///      （按 Date 去重，保留全量历史，防服务端只返回近期窗口）
///   5. 从 mirror jsonl 按日聚合
///
/// ⚠️ 与其它 provider 不同，Cursor 必须联网才能拿到用量（本地全 0）。因此勾选 Cursor 即联网：
/// 每次 refresh 会读本机 Cursor 凭证并请求 cursor.com。不想联网就在 Settings 取消勾选 Cursor。
/// 拉取失败时降级读已 mirror 的历史数据，不致命。
///
/// 安全：accessToken 只在内存用，不落盘明文（mirror 只存 token 数字）；只调 cursor.com 只读端点。
public struct CursorProvider: UsageProvider {
    public let id = "cursor"
    public let displayName = "Cursor"
    public let iconSymbol = "cursorarrow.rays"
    public let brandColor = "#000000"
    public var family: String? { nil }

    public init() {}

    private var stateDbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    /// mirror 文件：Cursor API 返回的逐次用量事件，按 key 覆盖存这里。
    /// static —— `CursorDetailScanner` 要读同一份文件，路径不能两处各写各的。
    static var mirrorFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/usageBar/cursor-usage-capture.jsonl")
            .path
    }

    private var mirrorPath: String { Self.mirrorFilePath }

    /// 主刷新调用：**只读本地 mirror**（快，~ms），不联网。
    /// 数据经 FileMtimeCache 进入持久账本（与其它 provider 一致，否则聚合读不到 Cursor）。
    /// 联网拉取由 `refreshFromNetwork()` 单独触发（见 docs/0510-Cursor接入/cursor-refresh-latency.md 方案 B）。
    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let path = mirrorPath
        guard let meta = FileMetadata.read(at: path) else { return [] }

        if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
            return entry.records
        }
        let records = aggregateFromMirror()
        let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
        await FileMtimeCache.shared.store(entry)
        return records
    }

    /// 联网拉取最新用量并写入 mirror（慢，~1.5s 网络往返）。
    /// 由 UsageViewModel 在主刷新之外异步触发；写完 mirror 后由下一次 fetchDailyRecords
    /// 经 FileMtimeCache（mirror mtime 变化触发 cache miss）重新解析。
    /// 返回是否真正写入了新数据（mirror 有变化）。
    @discardableResult
    public func refreshFromNetwork() async -> Bool {
        return (try? await refreshFromAPI()) ?? false
    }

    // MARK: - 步骤 3-4：联网拉取 + mirror

    @discardableResult
    private func refreshFromAPI() async throws -> Bool {
        guard let token = readAccessToken() else { return false }
        guard let userId = CursorJWT.userId(fromJWT: token) else { return false }

        let csv = try await CursorAPI.fetchUsageCSV(userId: userId, token: token)
        let events = CursorCSV.parse(csv)
        guard !events.isEmpty else { return false }

        return try mergeIntoMirror(events)
    }

    /// 读本地 SQLite 的 cursorAuth/accessToken（read-only，不干扰 Cursor）
    private func readAccessToken() -> String? {
        let uri = "file:\(stateDbPath)?mode=ro"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        let raw = String(cString: cStr)
        // value 可能是带引号的 JSON 字符串，去掉首尾引号
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// 把新事件并入 mirror：**按 key 覆盖的快照表**（v0.3.22 起；此前是「追加日志」）。
    /// 返回 mirror 是否有变化。
    ///
    /// key = `时间戳 + 模型`（见 `CursorUsageEvent.dedupeKey` 的根因说明）。同 key 取
    /// `total` 更大的那份 —— Cursor 的事件是**累计快照**，更大的就是更晚的、更接近终值的那一份。
    ///
    /// 顺带**把存量被污染的 mirror 就地收敛**：旧文件里同 key 的多份中间快照，读进来时只留终值，
    /// 写回后文件本身就干净了（**不需要单独的迁移脚本**）。
    ///
    /// ⚠️ mirror 必须保留、不能改成"每次全量重拉"：Cursor 服务端**只有当前账号的历史**
    /// （实测查最近 7/30/90/180/365 天都只返回同样 18 条，范围恒为账号创建至今）。
    /// 本机 mirror 里 2026-07-07 之前的 3,779,394 token 是**旧月抛号**的用量，服务端一条都不认。
    @discardableResult
    private func mergeIntoMirror(_ events: [CursorUsageEvent]) throws -> Bool {
        var best: [String: (total: Int, line: String)] = [:]
        var order: [String] = []           // 保持首次出现顺序，避免每次把整个文件重排
        var existingLineCount = 0

        if let existing = try? String(contentsOfFile: mirrorPath, encoding: .utf8) {
            for raw in existing.split(separator: "\n") {
                let s = String(raw)
                if s.isEmpty { continue }
                existingLineCount += 1
                guard let key = CursorUsageEvent.dedupeKey(fromJSONLine: s) else { continue }
                let total = CursorUsageEvent.totalTokens(fromJSONLine: s)
                if let cur = best[key] {
                    if total > cur.total { best[key] = (total, s) }   // 同 key 取终值
                } else {
                    best[key] = (total, s)
                    order.append(key)
                }
            }
        }

        // 存量收敛：同 key 的多份中间快照被折叠 → 行数变少 = 文件需要重写
        var changed = best.count != existingLineCount

        for ev in events {
            let key = ev.dedupeKey
            if let cur = best[key] {
                if ev.totalTokens > cur.total {
                    best[key] = (ev.totalTokens, ev.toJSONLine())    // 新终值覆盖旧快照
                    changed = true
                }
            } else {
                best[key] = (ev.totalTokens, ev.toJSONLine())
                order.append(key)
                changed = true
            }
        }
        guard changed else { return false }

        let dir = (mirrorPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = order.compactMap { best[$0]?.line }
        try (lines.joined(separator: "\n") + "\n").write(toFile: mirrorPath, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - 步骤 5：从 mirror 聚合

    /// 从 mirror 按日聚合。
    ///
    /// ⚠️ **聚合侧再兜一道**（v0.3.22）：同 `(时间戳, 模型)` 只取 total 最大的那份（= 累计快照的终值）。
    /// 这样**存量被污染的 mirror 在读取时就自动修正** —— 用户升级后即使还没联网刷新过
    /// （mirror 尚未被 `mergeIntoMirror` 重写），主行数字也已经是对的。**因此不需要迁移脚本。**
    /// 双保险的另一半在写入侧，两边缺一不可。
    private func aggregateFromMirror() -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: mirrorPath) else { return [] }
        let url = URL(fileURLWithPath: mirrorPath)
        var objs: [[String: Any]] = []
        try? JSONLReader.forEachLine(at: url) { objs.append($0) }
        return Self.aggregate(objects: objs, provider: id)
    }

    /// internal：供回归单测 `@testable` 调用（锁死「同 key 取终值、绝不相加」这条不变量）。
    static func aggregate(objects: [[String: Any]], provider: String) -> [FileDailyRecord] {
        struct Snapshot { var total: Int; var cacheRead: Int; var date: String }
        var best: [String: Snapshot] = [:]

        for obj in objects {
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr) else { continue }
            let model = (obj["model"] as? String) ?? ""
            let prompt = (obj["prompt_tokens"] as? Int) ?? 0
            let completion = (obj["completion_tokens"] as? Int) ?? 0
            let cacheRead = (obj["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreation = (obj["cache_creation_input_tokens"] as? Int) ?? 0
            // v0.3.10(2b)：total 补回 cache 两桶（此前只算 prompt+completion，漏缓存 → 少算约 87%）
            // 实测四列加总与 CSV 的 Total Tokens 完全闭合（56,835,066，一分不差）。
            let total = prompt + completion + cacheRead + cacheCreation
            if total == 0 { continue }

            let key = "\(tsStr)|\(model)"
            if let cur = best[key], cur.total >= total { continue }   // 已有更大（更晚）的快照
            best[key] = Snapshot(total: total, cacheRead: cacheRead,
                                 date: DailyAggregator.dateString(for: ts))
        }

        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]
        for snap in best.values {
            dailyTotals[snap.date, default: 0] += snap.total
            dailyCached[snap.date, default: 0] += snap.cacheRead   // 浅色：仅命中读取；cache_creation 归深色
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: provider, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }
}
