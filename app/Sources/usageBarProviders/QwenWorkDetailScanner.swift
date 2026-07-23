import Foundation
import SQLite3
import usageBarCore

struct QwenWorkSessionMeta: Sendable, Equatable {
    var databaseTitle: String?
    var customTitle: String?
    var aiTitle: String?
    var firstUserText: String?
    var cwd: String?
    var lastActivity: Date = .distantPast

    var resolvedTitle: String {
        databaseTitle
            ?? customTitle
            ?? aiTitle
            ?? firstUserText
            ?? cwd.map { ($0 as NSString).lastPathComponent }
            ?? "(无标题会话)"
    }

    mutating func merge(_ other: QwenWorkSessionMeta) {
        databaseTitle = other.databaseTitle ?? databaseTitle
        customTitle = other.customTitle ?? customTitle
        aiTitle = other.aiTitle ?? aiTitle
        firstUserText = firstUserText ?? other.firstUserText
        cwd = cwd ?? other.cwd
        lastActivity = max(lastActivity, other.lastActivity)
    }
}

/// 千问办公详情扫描器。
///
/// token 仍来自 `QwenWorkSegmentParser`（与主列表完全同源同口径）；会话标题只把
/// `agents.db` / transcript 当元数据补充，绝不从数据库的 context snapshot 取 token。
public actor QwenWorkDetailScanner {
    public static let shared = QwenWorkDetailScanner()

    private let sessionsRoot: URL
    private let projectsRoot: URL
    private let databasePath: String?

    private struct MetaCacheEntry {
        let mtime: Date
        let size: Int
        let metas: [String: QwenWorkSessionMeta]
    }

    private var transcriptCache: [String: MetaCacheEntry] = [:]
    private var databaseCache: MetaCacheEntry?

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwenworkcn/logs/sessions"),
        projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwenworkcn/projects"),
        databasePath: String? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenWorkCN/data/agents.db").path
    ) {
        self.sessionsRoot = sessionsRoot
        self.projectsRoot = projectsRoot
        self.databasePath = databasePath
    }

    public func detail(
        window: TimeWindow,
        weekStartMonday: Bool = true,
        now: Date = Date()
    ) async -> ProviderDetail {
        let events = await QwenWorkEventStore.shared.events(under: sessionsRoot)
        var metas = loadTranscriptMetas()
        for (sessionId, databaseMeta) in loadDatabaseMetas() {
            if var current = metas[sessionId] {
                current.merge(databaseMeta)
                metas[sessionId] = current
            } else {
                metas[sessionId] = databaseMeta
            }
        }
        return Self.compose(
            events: events,
            metas: metas,
            window: window,
            weekStartMonday: weekStartMonday,
            now: now
        )
    }

    public func invalidate() async {
        await QwenWorkEventStore.shared.invalidate()
        transcriptCache.removeAll()
        databaseCache = nil
    }

    static func compose(
        events: [QwenWorkUsageEvent],
        metas: [String: QwenWorkSessionMeta],
        window: TimeWindow,
        weekStartMonday: Bool,
        now: Date
    ) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(
            window, weekStartMonday: weekStartMonday, now: now
        )

        var total = TokenBreakdown()
        var byModel: [String: TokenBreakdown] = [:]
        var bySession: [String: (tokens: TokenBreakdown, last: Date)] = [:]

        for event in events where inWindow(event.date) {
            total.add(event.tokens)
            byModel[event.model, default: TokenBreakdown()].add(event.tokens)
            var session = bySession[event.sessionId] ?? (TokenBreakdown(), event.timestamp)
            session.tokens.add(event.tokens)
            session.last = max(session.last, event.timestamp)
            bySession[event.sessionId] = session
        }

        // qwork-ultimate 等是套餐/路由别名，不是真实模型 id，无法诚实折算 API 价格。
        let models = byModel.map {
            ModelDetailRecord(modelId: $0.key, tokens: $0.value, cost: 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        let sessions = bySession.map { sessionId, value -> SessionDetailRecord in
            let meta = metas[sessionId]
            return SessionDetailRecord(
                sessionId: sessionId,
                title: meta?.resolvedTitle ?? "(无标题会话)",
                subtitle: String(sessionId.prefix(8)),
                lastActivity: max(value.last, meta?.lastActivity ?? .distantPast),
                tokens: value.tokens,
                cost: 0
            )
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(
            providerId: "qwen-work",
            windowId: window.id,
            tokens: total,
            cost: 0,
            models: models,
            sessions: sessions
        )
    }

    // MARK: - 会话标题：transcript fallback

    private func loadTranscriptMetas() -> [String: QwenWorkSessionMeta] {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else { return [:] }
        let files = JSONLReader.findFiles(under: projectsRoot) { $0.pathExtension == "jsonl" }
        var result: [String: QwenWorkSessionMeta] = [:]

        for url in files {
            let path = url.path
            guard let fileMeta = FileMetadata.read(at: path) else { continue }
            let parsed: [String: QwenWorkSessionMeta]
            if let cached = transcriptCache[path],
               cached.mtime == fileMeta.mtime, cached.size == fileMeta.size {
                parsed = cached.metas
            } else {
                parsed = Self.parseTranscriptMeta(url: url)
                transcriptCache[path] = MetaCacheEntry(
                    mtime: fileMeta.mtime, size: fileMeta.size, metas: parsed
                )
            }

            for (sessionId, meta) in parsed {
                if var current = result[sessionId] {
                    current.merge(meta)
                    result[sessionId] = current
                } else {
                    result[sessionId] = meta
                }
            }
        }
        return result
    }

    static func parseTranscriptMeta(url: URL) -> [String: QwenWorkSessionMeta] {
        var metas: [String: QwenWorkSessionMeta] = [:]
        try? JSONLReader.forEachLine(at: url) { obj in
            guard let sessionId = (obj["sessionId"] as? String)
                    ?? (obj["session_id"] as? String),
                  !sessionId.isEmpty
            else { return }

            let timestamp = (obj["timestamp"] as? String).flatMap(ISODateParser.parse)
            var meta = metas[sessionId] ?? QwenWorkSessionMeta()
            if let timestamp { meta.lastActivity = max(meta.lastActivity, timestamp) }
            if meta.cwd == nil { meta.cwd = obj["cwd"] as? String }

            switch obj["type"] as? String {
            case "custom-title":
                if let title = nonEmpty(obj["customTitle"] as? String) {
                    meta.customTitle = title
                }
            case "ai-title":
                if let title = nonEmpty(obj["aiTitle"] as? String) {
                    meta.aiTitle = title
                }
            case "user":
                if meta.firstUserText == nil,
                   (obj["isMeta"] as? Bool) != true,
                   (obj["isSidechain"] as? Bool) != true,
                   let message = obj["message"] as? [String: Any] {
                    meta.firstUserText = plainUserText(message["content"])
                }
            default:
                break
            }
            metas[sessionId] = meta
        }
        return metas
    }

    private static func plainUserText(_ content: Any?) -> String? {
        func clean(_ value: String) -> String? {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
            return String(text.prefix(80))
        }

        if let value = content as? String { return clean(value) }
        if let parts = content as? [[String: Any]] {
            for part in parts where (part["type"] as? String) == "text" {
                if let value = part["text"] as? String, let text = clean(value) {
                    return text
                }
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 会话标题：agents.db（侧栏真实标题，最高优先级）

    private func loadDatabaseMetas() -> [String: QwenWorkSessionMeta] {
        guard let databasePath, let meta = databaseMetadata(path: databasePath) else { return [:] }
        if let cached = databaseCache,
           cached.mtime == meta.mtime, cached.size == meta.size {
            return cached.metas
        }
        let parsed = Self.queryDatabaseMetas(path: databasePath)
        databaseCache = MetaCacheEntry(mtime: meta.mtime, size: meta.size, metas: parsed)
        return parsed
    }

    private func databaseMetadata(path: String) -> (mtime: Date, size: Int)? {
        guard let db = FileMetadata.read(at: path) else { return nil }
        let wal = FileMetadata.read(at: path + "-wal")
        return (
            max(db.mtime, wal?.mtime ?? .distantPast),
            db.size + (wal?.size ?? 0)
        )
    }

    static func queryDatabaseMetas(path: String) -> [String: QwenWorkSessionMeta] {
        let uri = "file:\(path)?mode=ro"
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT s.session_id,
               COALESCE(NULLIF(s.name, ''), NULLIF(c.name, '')),
               s.updated_at
          FROM sub_chats AS s
          LEFT JOIN chats AS c ON c.id = s.chat_id
         WHERE s.session_id IS NOT NULL
           AND s.session_id != ''
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: QwenWorkSessionMeta] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionChars = sqlite3_column_text(statement, 0) else { continue }
            let sessionId = String(cString: sessionChars)
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let rawTimestamp = sqlite3_column_int64(statement, 2)
            let seconds = rawTimestamp > 10_000_000_000
                ? Double(rawTimestamp) / 1000.0
                : Double(rawTimestamp)
            result[sessionId] = QwenWorkSessionMeta(
                databaseTitle: nonEmpty(title),
                lastActivity: seconds > 0
                    ? Date(timeIntervalSince1970: seconds)
                    : .distantPast
            )
        }
        return result
    }
}
