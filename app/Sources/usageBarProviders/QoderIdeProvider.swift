import Foundation
import SQLite3
import usageBarCore

/// Qoder IDE provider(SharedClientCache SQLite 版)
///
/// 数据源:`~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db`
///   - 表:`chat_message`
///   - 关键字段:`role` / `token_info`(JSON) / `model_info`(JSON) / `gmt_create`(unix ms)
///
/// token_info JSON schema(OpenAI 兼容 3 列):
/// ```json
/// {"prompt_tokens": 39005, "completion_tokens": 67, "cached_tokens": 37485, "max_input_tokens": 200000}
/// ```
///
/// 映射到 Anthropic 4 列(跟 Qoder CLI 保持一致):
///   - `input` = `prompt_tokens - cached_tokens`
///   - `cache_read` = `cached_tokens`
///   - `cache_creation` = 0(Qoder 协议不暴露此列)
///   - `output` = `completion_tokens`
///
/// 实测覆盖率(2026-05-28 本机):877 条 assistant 消息,676 条(77%)含完整 token_info,
/// 时间跨度 2025-12-18 ~ 2026-05-25。剩余 23% 是 chat 被中断 / error 的行,token_info 为空,直接 skip。
///
/// 注意:Go binary 给 IDE Electron 的 stream-json 通道里 token 4 列值是 0,
/// 但 IDE 端 chat panel 右上角能显示 token 数 —— 它走的是另一条水路:
/// IDE 直接把 token 写进这个 SharedClientCache 持久化层,跟 stream-json 通道相互独立。
///
/// 数据源发现路径参考公开项目 https://github.com/juliantanx/aiusage
/// (声明 `chat_message` 表含 token),实测本机 db 验证成立。
public struct QoderIdeProvider: UsageProvider {
    public let id = "qoder-ide"
    public let displayName = "Qoder IDE"
    public let iconSymbol = "wand.and.stars"
    public let brandColor = "#0E5F7A"
    public var family: String? { "qoder" }

    private var dbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Qoder/SharedClientCache/cache/db/local.db")
            .path
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let path = dbPath
        // SQLite WAL 模式下,新写入先进 db-wal,主 db 文件 mtime 不更新直到 checkpoint。
        // 必须合并 db + db-wal 两个文件做 cache key,否则 IDE 写新消息 usageBar 看不到。
        // 实测 bug:2026-05-28 用户在 Qoder IDE 发消息后,db mtime 仍是 5/27,wal mtime 才是 5/28。
        guard let meta = sqliteMetadataWithWAL(dbPath: path) else { return [] }

        if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {

        // v0.3.33：明细落进持久账本（详情页从此读账本，源被清理/锁住也能展开）。
        // 写成一条**合成条目**（非真实路径 + 每轮覆盖），不参与 mtime 缓存命中。
        // ⚠️ 必须在**所有** return 之前写：命中 mtime 缓存的那条快路径也要写，
        // 否则第二轮起就再也不更新明细（首扫恰好没数据的 provider 会永远空着）。
        await Self.storeDetails(QoderIdeDetailScanner.shared)
            return entry.records
        }

        let records = (try? parseDB(path: path)) ?? []
        let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
        await FileMtimeCache.shared.store(entry)


        // v0.3.33：明细落进持久账本（详情页从此读账本，源被清理/锁住也能展开）。
        // 写成一条**合成条目**（非真实路径 + 每轮覆盖），不参与 mtime 缓存命中。
        // ⚠️ 必须在**所有** return 之前写：命中 mtime 缓存的那条快路径也要写，
        // 否则第二轮起就再也不更新明细（首扫恰好没数据的 provider 会永远空着）。
        await Self.storeDetails(QoderIdeDetailScanner.shared)
        return records
    }

    /// 合并 db 主文件和 db-wal 文件的元数据,得到一个能感知 WAL 变化的 cache key。
    /// - mtime 取两者最大值(db checkpoint 或 wal 写入,谁新用谁)
    /// - size 取两者之和(wal 增长即可触发 cache miss)
    private func sqliteMetadataWithWAL(dbPath: String) -> (mtime: Date, size: Int)? {
        guard let db = FileMetadata.read(at: dbPath) else { return nil }
        let wal = FileMetadata.read(at: dbPath + "-wal")
        let mtime = max(db.mtime, wal?.mtime ?? Date.distantPast)
        let size = db.size + (wal?.size ?? 0)
        return (mtime, size)
    }

    /// 用系统 SQLite3 库读取(macOS 自带,无需链接配置)。
    /// 以 read-only 模式打开(URI),允许 WAL 并发,不干扰 Qoder 自身写入。
    private func parseDB(path: String) throws -> [FileDailyRecord] {
        // URI 形式:`file:<path>?mode=ro&immutable=0&nolock=0`(留 nolock=0 让 WAL 工作)
        // 注意 path 里如果有特殊字符需要 percent-encode,但应用路径稳定,简化处理
        let uri = "file:\(path)?mode=ro"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT gmt_create, token_info
          FROM chat_message
         WHERE role='assistant'
           AND token_info IS NOT NULL
           AND token_info != ''
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let gmtMs = sqlite3_column_int64(stmt, 0)
            guard let cStr = sqlite3_column_text(stmt, 1) else { continue }
            let tokenInfoStr = String(cString: cStr)

            guard let parsed = parseTokenInfoTotal(tokenInfoStr) else { continue }
            if parsed.total == 0 { continue }

            // gmt_create 是 unix ms
            let date = DailyAggregator.dateString(for: Date(timeIntervalSince1970: TimeInterval(gmtMs) / 1000.0))
            dailyTotals[date, default: 0] += parsed.total
            dailyCached[date, default: 0] += parsed.cached   // 浅色：cached_tokens（prompt 子集）
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }

    /// 解析 token_info JSON,返回 Anthropic 4 列等价总和(= prompt + completion,因为 cached 已含在 prompt 里)。
    /// 容错:个别行 model_info JSON malformed,但 token_info 实测都规范;仍做防御。
    private func parseTokenInfoTotal(_ jsonStr: String) -> (total: Int, cached: Int)? {
        guard let data = jsonStr.data(using: .utf8) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let prompt = (obj["prompt_tokens"] as? Int) ?? 0
        let completion = (obj["completion_tokens"] as? Int) ?? 0
        let cached = (obj["cached_tokens"] as? Int) ?? 0

        // Anthropic 4 列等价(cached 已含在 prompt 里,聚合 total 时抵消):
        //   input            = prompt - cached
        //   cache_creation   = 0
        //   cache_read       = cached          ← 浅色（命中读取，prompt 子集）
        //   output           = completion
        //   total            = (prompt - cached) + 0 + cached + completion = prompt + completion
        return (prompt + completion, cached)
    }

    /// 把 scanner 的全量明细写进账本（合成 key，每轮覆盖）。
    private static func storeDetails(_ scanner: QoderIdeDetailScanner) async {
        let details = await scanner.allDetails()
        guard !details.isEmpty else { return }
        await FileMtimeCache.shared.store(FileCacheEntry(
            filePath: "usagebar://detail-ledger/qoder-ide", mtime: Date(), size: details.count,
            records: [], details: details))
    }

}
