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

    /// mirror 文件：Cursor API 返回的逐次用量事件，去重累积存这里
    private var mirrorPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/usageBar/cursor-usage-capture.jsonl")
            .path
    }

    /// 主刷新调用：**只读本地 mirror**（快，~ms），不联网。
    /// 数据经 FileMtimeCache 进入持久账本（与其它 provider 一致，否则聚合读不到 Cursor）。
    /// 联网拉取由 `refreshFromNetwork()` 单独触发（见 docs/cursor-refresh-latency.md 方案 B）。
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

    /// 把新事件并入 mirror jsonl，按 dedupeKey 去重（保留全量历史）。返回是否写入了新数据。
    @discardableResult
    private func mergeIntoMirror(_ events: [CursorUsageEvent]) throws -> Bool {
        var seen = Set<String>()
        var lines: [String] = []

        // 读已有 mirror，收集 dedupeKey
        if let existing = try? String(contentsOfFile: mirrorPath, encoding: .utf8) {
            for line in existing.split(separator: "\n") {
                let s = String(line)
                if s.isEmpty { continue }
                if let key = CursorUsageEvent.dedupeKey(fromJSONLine: s) {
                    seen.insert(key)
                }
                lines.append(s)
            }
        }

        // 追加新事件（去重）
        var added = 0
        for ev in events where !seen.contains(ev.dedupeKey) {
            seen.insert(ev.dedupeKey)
            lines.append(ev.toJSONLine())
            added += 1
        }
        guard added > 0 else { return false }

        // 确保目录存在
        let dir = (mirrorPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: mirrorPath, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - 步骤 5：从 mirror 聚合

    private func aggregateFromMirror() -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: mirrorPath) else { return [] }
        let url = URL(fileURLWithPath: mirrorPath)

        var dailyTotals: [String: Int] = [:]
        try? JSONLReader.forEachLine(at: url) { obj in
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr) else { return }
            let prompt = (obj["prompt_tokens"] as? Int) ?? 0
            let completion = (obj["completion_tokens"] as? Int) ?? 0
            let total = prompt + completion
            if total == 0 { return }
            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token)
        }
    }
}
