import SQLite3
import XCTest
import usageBarCore

@testable import usageBarProviders

/// OpenCode provider 消息级归因 + subagent 收敛的单测。
///
/// 库表结构对齐 opencode 官方 schema（anomalyco/opencode
/// `packages/core/src/database/schema.gen.ts`，2026-07 实测 1.17.16 初始化产物一致）：
/// message.data 是 AssistantMessage JSON（$.tokens.{input,output,reasoning,cache.{read,write}}
/// / $.cost / $.modelID / $.role），session 表 tokens_* 只是它的按会话 SUM。
final class OpenCodeTests: XCTestCase {

    // MARK: - DB 解析（真 schema 临时库）

    func testLoadParsesOfficialSchema() throws {
        let now = Date()
        let dbPath = try makeTempDB(
            sessions: [
                ("ses_root", nil, "根会话"),
                ("ses_sub", "ses_root", "subagent 子任务"),
            ],
            messages: [
                // (id, sessionId, time, modelID(json 值或 "null"), input, output, reasoning, cacheRead, cacheWrite, cost)
                ("msg_1", "ses_root", now, "\"claude-opus-4-8\"", 100, 50, 0, 200, 30, 0.05),
                ("msg_2", "ses_sub", now, "null", 40, 20, 10, 0, 0, 0.01),
                ("msg_zero", "ses_root", now, "\"claude-opus-4-8\"", 0, 0, 0, 0, 0, 0),  // 全 0 → 跳过
            ])

        let (messages, sessions) = OpenCodeDB.load(dbPath: dbPath)

        XCTAssertEqual(messages.count, 2, "全 0 token 的消息应被过滤")
        let m1 = try XCTUnwrap(messages.first { $0.sessionId == "ses_root" })
        XCTAssertEqual(m1.tokens.input, 100)
        XCTAssertEqual(m1.tokens.output, 50)
        XCTAssertEqual(m1.tokens.cacheRead, 200)
        XCTAssertEqual(m1.tokens.cacheCreate, 30)
        XCTAssertEqual(m1.tokens.total, 380)
        XCTAssertEqual(m1.cost, 0.05, accuracy: 1e-9, "db cost>0 用真实值")
        XCTAssertEqual(m1.modelId, "claude-opus-4-8")

        let m2 = try XCTUnwrap(messages.first { $0.sessionId == "ses_sub" })
        XCTAssertEqual(m2.modelId, "unknown", "modelID 为 NULL 时兜底")
        XCTAssertEqual(m2.tokens.reasoning, 10)
        XCTAssertEqual(m2.tokens.output, 30, "opencode 存的 output 不含 reasoning，解析时补回（app 口径 reasoning ⊂ output）")
        XCTAssertEqual(m2.tokens.total, 70)

        XCTAssertEqual(sessions["ses_sub"]?.parentId, "ses_root")
        XCTAssertNil(sessions["ses_root"]?.parentId)
    }

    func testCostFallbackToEquivalentPricing() throws {
        // gpt-5.5-fast 远程表没有精确键 → 剥纯字母尾段规整到 gpt-5.5（一级价源=远程表）
        let fixture = Data(#"{"providers":{"openai":{"gpt-5.5":{"input":5,"output":30,"cache_read":0.5}}}}"#.utf8)
        XCTAssertTrue(RemotePricing.shared.injectForTesting(fixture))
        let now = Date()
        let dbPath = try makeTempDB(
            sessions: [("ses_r", nil, "订阅会话")],
            messages: [
                // 订阅登录 cost=0 → gpt-5.5 等效价：1000×$5/1M + (100+50)×$30/1M = $0.0095
                ("msg_g", "ses_r", now, "\"gpt-5.5-fast\"", 1000, 100, 50, 0, 0, 0),
                // 表里没有的模型 cost=0 → 保持 0（宁显 $0 不猜价）
                ("msg_u", "ses_r", now, "\"glm-5.2\"", 1000, 100, 0, 0, 0, 0),
            ])

        let messages = OpenCodeDB.load(dbPath: dbPath).messages
        let g = try XCTUnwrap(messages.first { $0.modelId == "gpt-5.5-fast" })
        XCTAssertEqual(g.cost, 0.0095, accuracy: 1e-9)
        let u = try XCTUnwrap(messages.first { $0.modelId == "glm-5.2" })
        XCTAssertEqual(u.cost, 0)
    }

    func testUnifiedPricingRemoteFirstRouting() {
        // 2026-07-12 起一级价源=远程表，内置手工表退役（0712-价格统一走远程表 spec）
        let fixture = Data("""
        {"providers":{
          "anthropic":{"claude-opus-4-8":{"input":5,"output":25,"cache_read":0.5,"cache_write":6.25}},
          "openai":{"gpt-5.6-sol":{"input":5,"output":30,"cache_read":0.5,"cache_write":6.25},
                    "gpt-5.3-codex":{"input":1.75,"output":14,"cache_read":0.175}}
        }}
        """.utf8)
        XCTAssertTrue(RemotePricing.shared.injectForTesting(fixture))

        // 精确命中（本次 bug 主角：5.6-sol 不再落到 gpt-5 老价）
        XCTAssertEqual(UnifiedPricing.inputRate(for: "gpt-5.6-sol"), 5 / 1_000_000)
        XCTAssertEqual(UnifiedPricing.outputRate(for: "gpt-5.6-sol"), 30.0 / 1_000_000)
        // 归一化：去 -YYYYMMDD 日期后缀
        XCTAssertEqual(UnifiedPricing.inputRate(for: "claude-opus-4-8-20260101"), 5 / 1_000_000)
        // 别名：codex-auto-review（models.dev 没有）→ gpt-5.3-codex
        XCTAssertEqual(UnifiedPricing.outputRate(for: "codex-auto-review"), 14.0 / 1_000_000)
        // 缓存写：5m 直接用远程 cache_write；1h 档远程没有，按官方倍率 input×2 补
        XCTAssertEqual(UnifiedPricing.cacheWrite5mRate(for: "claude-opus-4-8"), 6.25 / 1_000_000)
        XCTAssertEqual(UnifiedPricing.cacheWrite1hRate(for: "claude-opus-4-8"), 10.0 / 1_000_000)
        // 纯数字尾段绝不剥：opus-4-9 不能吃到 opus-4-8 的价
        XCTAssertTrue(UnifiedPricing.hasNoPricing(for: "claude-opus-4-9"))

        // 空表（首启断网）：claude/gpt 同样 $0 + 无价目（1c 口径，不再有内置兜底）
        clearRemotePricing()
        XCTAssertEqual(UnifiedPricing.inputRate(for: "claude-opus-4-8"), 0)
        XCTAssertTrue(UnifiedPricing.hasNoPricing(for: "claude-opus-4-8"))
    }

    // MARK: - 远程价目（models.dev 瘦身表）

    func testRemotePricingLookupAndUnifiedFallback() throws {
        let fixture = Data("""
        {"providers":{
          "zai":{"glm-5.2":{"input":0.6,"output":2.2,"cache_read":0.11}},
          "openrouter":{"glm-5.2":{"input":9,"output":9}},
          "google":{"gemini-3-pro":{"input":1.25,"output":10,"cache_read":0.31,"cache_write":1.625}}
        }}
        """.utf8)
        XCTAssertTrue(RemotePricing.shared.injectForTesting(fixture))

        // (provider, model) 精确命中
        XCTAssertEqual(RemotePricing.shared.rate(provider: "zai", model: "glm-5.2")?.input, 0.6)
        // 扁平表:官方渠道(zai 在 canonical 序)优先于转售渠道(openrouter)
        XCTAssertEqual(RemotePricing.shared.rate(provider: nil, model: "glm-5.2")?.input, 0.6)
        XCTAssertEqual(RemotePricing.shared.rate(provider: "不存在的渠道", model: "glm-5.2")?.input, 0.6)

        // UnifiedPricing 兜底链:未知厂商模型经远程表有价了
        XCTAssertEqual(UnifiedPricing.inputRate(for: "glm-5.2", provider: "zai"), 0.6 / 1_000_000)
        XCTAssertEqual(UnifiedPricing.cacheWrite5mRate(for: "gemini-3-pro"), 1.625 / 1_000_000)
        XCTAssertFalse(UnifiedPricing.hasNoPricing(for: "glm-5.2"))
        XCTAssertTrue(UnifiedPricing.hasNoPricing(for: "totally-unknown-model"))
        // claude/gpt 同走远程：此 fixture 无 anthropic → 查无价（内置兜底已退役）
        XCTAssertTrue(UnifiedPricing.hasNoPricing(for: "claude-opus-4-8"))
    }

    func testOpenCodeCostFallbackViaRemotePricing() throws {
        let fixture = Data(#"{"providers":{"zai":{"glm-5.2":{"input":0.6,"output":2.2}}}}"#.utf8)
        XCTAssertTrue(RemotePricing.shared.injectForTesting(fixture))
        let now = Date()
        let dbPath = try makeTempDB(
            sessions: [("ses_r", nil, "glm 订阅会话")],
            messages: [("msg_g", "ses_r", now, "\"glm-5.2\"", 1000, 100, 0, 0, 0, 0)])

        let messages = OpenCodeDB.load(dbPath: dbPath).messages
        let g = try XCTUnwrap(messages.first)
        // 过去显示 $0 的 glm,经远程表折算:1000×$0.6/1M + 100×$2.2/1M = $0.00082
        XCTAssertEqual(g.cost, 0.00082, accuracy: 1e-12)
    }

    func testLoadMissingDBReturnsEmpty() {
        let (messages, sessions) = OpenCodeDB.load(dbPath: "/nonexistent/opencode.db")
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - 按消息日归因（核心：跨天会话不再全记创建日）

    func testDailyAttributionByMessageDate() {
        let now = Date()
        let d0 = DailyAggregator.dateString(for: now)
        let d1 = DailyAggregator.dateString(for: now.addingTimeInterval(-86400))

        let rows = [
            msg("ses_a", now.addingTimeInterval(-86400), tokens: tb(input: 1000, cacheRead: 500)),
            msg("ses_a", now, tokens: tb(input: 600, output: 300)),  // 同一会话、次日消息
            msg("ses_b", now, tokens: tb(input: 2000, cacheRead: 100)),
        ]
        let records = OpenCodeDB.dailyRecords(from: rows, providerId: "opencode")
        let byDate = Dictionary(uniqueKeysWithValues: records.map { ($0.date, $0) })

        XCTAssertEqual(byDate[d1]?.token, 1500)
        XCTAssertEqual(byDate[d1]?.cachedToken, 500)
        XCTAssertEqual(byDate[d0]?.token, 3000, "跨天会话今天的消息必须记在今天")
        XCTAssertEqual(byDate[d0]?.cachedToken, 100)
    }

    // MARK: - subagent 收敛

    func testSubagentRollsUpToRootSession() {
        let now = Date()
        let sessions: [String: OpenCodeDB.SessionInfo] = [
            "ses_root": .init(title: "根会话", parentId: nil),
            "ses_sub": .init(title: "subagent", parentId: "ses_root"),
            "ses_b": .init(title: "独立会话", parentId: nil),
        ]
        let rows = [
            msg("ses_root", now, tokens: tb(input: 900)),
            msg("ses_sub", now, tokens: tb(input: 700)),
            msg("ses_b", now, tokens: tb(input: 8800)),
        ]
        let detail = OpenCodeDetailScanner.compose(
            messages: rows, sessions: sessions, window: .today, weekStartMonday: true, now: now)

        XCTAssertEqual(detail.sessions.count, 2, "子会话应收敛进根会话，不单独成行")
        let root = detail.sessions.first { $0.sessionId == "ses_root" }
        XCTAssertEqual(root?.tokens.total, 1600, "根会话 = 自己 900 + 子会话 700")
        XCTAssertEqual(root?.title, "根会话")
        XCTAssertEqual(detail.tokens.total, 10400)
    }

    func testParentChainLoopTerminates() {
        let sessions: [String: OpenCodeDB.SessionInfo] = [
            "a": .init(title: "a", parentId: "b"),
            "b": .init(title: "b", parentId: "a"),  // 环
        ]
        XCTAssertEqual(OpenCodeDB.rootSessionId(of: "a", in: sessions), "b")
        XCTAssertEqual(OpenCodeDB.rootSessionId(of: "x", in: sessions), "x", "查不到的会话停在原地")
    }

    // MARK: - 明细 = 主行 口径一致

    func testDetailTodayMatchesDailyRecord() {
        let now = Date()
        let today = DailyAggregator.dateString(for: now)
        let rows = [
            msg("ses_a", now.addingTimeInterval(-2 * 86400), tokens: tb(input: 3800)),
            msg("ses_a", now, tokens: tb(input: 900)),
            msg("ses_b", now, tokens: tb(input: 8800, cacheRead: 200)),
        ]
        let daily = OpenCodeDB.dailyRecords(from: rows, providerId: "opencode")
            .first { $0.date == today }
        let detail = OpenCodeDetailScanner.compose(
            messages: rows, sessions: [:], window: .today, weekStartMonday: true, now: now)

        XCTAssertEqual(detail.tokens.total, daily?.token, "明细 Hero 合计必须与主行同口径")
        XCTAssertEqual(detail.tokens.cached, daily?.cachedToken)
    }

    // MARK: - 模型友好名

    func testFriendlyModelName() {
        XCTAssertEqual(OpenCodeDetailScanner.friendlyModelName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(OpenCodeDetailScanner.friendlyModelName("gpt-5.5-fast"), "GPT-5.5-fast")
        XCTAssertEqual(OpenCodeDetailScanner.friendlyModelName("glm-5.2"), "Glm 5.2")
        XCTAssertEqual(OpenCodeDetailScanner.friendlyModelName("gemini-3-pro"), "Gemini 3 Pro")
    }

    // MARK: - helpers

    private func tb(input: Int = 0, output: Int = 0, cacheRead: Int = 0) -> TokenBreakdown {
        TokenBreakdown(input: input, output: output, cacheRead: cacheRead)
    }

    private func msg(_ sid: String, _ time: Date, tokens: TokenBreakdown,
                     model: String = "claude-opus-4-8", cost: Double = 0) -> OpenCodeDB.MessageRow {
        OpenCodeDB.MessageRow(sessionId: sid, date: DailyAggregator.dateString(for: time),
                              time: time, modelId: model, providerId: "anthropic",
                              tokens: tokens, cost: cost)
    }

    /// 清空远程价目表（RemotePricing 是进程级单例,涉价测试必须显式设定自己的表,避免顺序耦合）
    private func clearRemotePricing() {
        XCTAssertTrue(RemotePricing.shared.injectForTesting(Data(#"{"providers":{}}"#.utf8)))
    }

    /// 按 opencode 官方 schema 建临时库并插入 assistant 消息
    private func makeTempDB(
        sessions: [(id: String, parent: String?, title: String)],
        messages: [(id: String, sid: String, time: Date, modelJson: String,
                    input: Int, output: Int, reasoning: Int, cacheRead: Int, cacheWrite: Int, cost: Double)]
    ) throws -> String {
        let path = NSTemporaryDirectory() + "opencode-test-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        exec(db, """
            CREATE TABLE session (
              id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
              slug text NOT NULL, directory text NOT NULL, title text NOT NULL, version text NOT NULL,
              cost real DEFAULT 0 NOT NULL,
              tokens_input integer DEFAULT 0 NOT NULL, tokens_output integer DEFAULT 0 NOT NULL,
              tokens_reasoning integer DEFAULT 0 NOT NULL,
              tokens_cache_read integer DEFAULT 0 NOT NULL, tokens_cache_write integer DEFAULT 0 NOT NULL,
              model text, time_created integer NOT NULL, time_updated integer NOT NULL);
            CREATE TABLE message (
              id text PRIMARY KEY, session_id text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            """)

        for s in sessions {
            let parent = s.parent.map { "'\($0)'" } ?? "NULL"
            exec(db, """
                INSERT INTO session (id, project_id, parent_id, slug, directory, title, version,
                                     time_created, time_updated)
                VALUES ('\(s.id)', 'prj', \(parent), '\(s.id)', '/tmp', '\(s.title)', '1.17.16', 0, 0);
                """)
        }
        for m in messages {
            let ms = Int64(m.time.timeIntervalSince1970 * 1000)
            let data = """
                {"id":"\(m.id)","sessionID":"\(m.sid)","role":"assistant",\
                "time":{"created":\(ms)},"modelID":\(m.modelJson),"providerID":"anthropic",\
                "cost":\(m.cost),"tokens":{"input":\(m.input),"output":\(m.output),\
                "reasoning":\(m.reasoning),"cache":{"read":\(m.cacheRead),"write":\(m.cacheWrite)}}}
                """
            exec(db, """
                INSERT INTO message (id, session_id, time_created, time_updated, data)
                VALUES ('\(m.id)', '\(m.sid)', \(ms), \(ms), '\(data)');
                """)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        XCTAssertEqual(rc, SQLITE_OK, err.map { String(cString: $0) } ?? "")
    }
}
