import XCTest
import SQLite3
import usageBarCore
@testable import usageBarProviders

/// v0.3.47「按模型」输出速度列：各来源的耗时取法 + 账本兼容 + 汇总口径。
///
/// 口径（2026-10-13 用户拍板）：端到端 = 输出 token ÷ 从发出请求到回答完的秒数；所有回复都计入，
/// 按「总输出 ÷ 总秒数」加权；只剔除单条耗时 ≤ 0 或 ≥ 30 分钟的异常记录。
final class OutputSpeedTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("output-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ lines: [String], to name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func sum(_ details: [FileDetailRecord]) -> GenerationTiming {
        var t = GenerationTiming()
        for d in details { if let x = d.timing { t.add(x) } }
        return t
    }

    // MARK: - 累加器

    func testTimingRejectsAbnormalDurations() {
        var t = GenerationTiming()
        XCTAssertTrue(t.add(output: 100, millis: 2_000))
        XCTAssertFalse(t.add(output: 50, millis: 0), "耗时 0 = 时间戳坏了")
        XCTAssertFalse(t.add(output: 50, millis: -5), "结束早于开始")
        XCTAssertFalse(t.add(output: 50, millis: GenerationTiming.maxMillis), "≥ 30 分钟 = 电脑睡眠")
        XCTAssertFalse(t.add(output: 50, millis: nil), "拿不到耗时")
        XCTAssertTrue(t.add(output: 0, millis: 500), "零输出的回复照样计入（所有回复都算）")
        XCTAssertEqual(t, GenerationTiming(output: 100, millis: 2_500))
        XCTAssertEqual(t.tokensPerSecond!, 40, accuracy: 0.001)
        XCTAssertNil(GenerationTiming().tokensPerSecond, "没有计时回复 → 那一格留空")
    }

    // MARK: - 账本兼容：不 bump schema，旧条目原样可读

    func testOldLedgerDetailDecodesWithoutTimingAndTriggersReparse() throws {
        let rec = FileDetailRecord(provider: "claude-code", date: "2026-10-13", sessionId: "s", title: "t",
                                   model: "m", lastActivity: Date(timeIntervalSince1970: 0),
                                   tokens: TokenBreakdown(input: 1, output: 2),
                                   timing: GenerationTiming(output: 2, millis: 1_000))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) as! [String: Any]
        XCTAssertEqual(json["timedOutput"] as? Int, 2)
        json.removeValue(forKey: "timedOutput"); json.removeValue(forKey: "timedMillis")   // = v0.3.46 写的条目
        let old = try JSONDecoder().decode(FileDetailRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.timing)
        XCTAssertEqual(old.tokens, rec.tokens, "token 一个不差")

        let oldEntry = FileCacheEntry(filePath: "/x", mtime: Date(), size: 1, records: [], details: [old])
        XCTAssertFalse(oldEntry.detailsHaveTiming(provider: "claude-code"), "旧条目命中缓存时要重解析补耗时")
        XCTAssertTrue(oldEntry.detailsHaveTiming(provider: "cowork"), "只看本来源的明细")
        let newEntry = FileCacheEntry(filePath: "/x", mtime: Date(), size: 1, records: [], details: [rec])
        XCTAssertTrue(newEntry.detailsHaveTiming(provider: "claude-code"))
        XCTAssertTrue(FileCacheEntry(filePath: "/y", mtime: Date(), size: 0, records: [])
            .detailsHaveTiming(provider: "claude-code"), "没有明细的文件不需要重解析")
    }

    // MARK: - 汇总：按模型分别相加再相除

    func testAggregatorWeightsByTotalsPerModelAndKeepsOldRecordsBlank() {
        func d(_ date: String, _ model: String, out: Int, timing: GenerationTiming?) -> FileDetailRecord {
            FileDetailRecord(provider: "claude-code", date: date, sessionId: "s-\(date)", title: "",
                             model: model, lastActivity: Date(), tokens: TokenBreakdown(input: 10, output: out),
                             timing: timing)
        }
        let details = [
            d("2026-10-12", "opus", out: 100, timing: GenerationTiming(output: 100, millis: 1_000)),
            d("2026-10-13", "opus", out: 900, timing: GenerationTiming(output: 900, millis: 19_000)),
            d("2026-10-13", "haiku", out: 50, timing: nil),                          // 旧版本解析的条目
            d("2026-10-13", "sonnet", out: 5, timing: GenerationTiming()),           // 新口径但没有合法耗时
        ]
        let all = LedgerDetailAggregator.aggregate(providerId: "claude-code", details: details, window: .all)
        let opus = all.models.first { $0.modelId == "opus" }!
        XCTAssertEqual(opus.tokensPerSecond!, 1_000.0 / 20, accuracy: 0.001, "两天 1000 token / 20 秒，不是两天速度取平均")
        XCTAssertNil(all.models.first { $0.modelId == "haiku" }!.tokensPerSecond)
        XCTAssertNil(all.models.first { $0.modelId == "sonnet" }!.tokensPerSecond)
        XCTAssertEqual(all.tokens.total, details.reduce(0) { $0 + $1.tokens.total }, "速度不影响任何 token 合计")
    }

    // MARK: - Claude Code / Cowork / Qoder CLI transcript

    private func claudeLine(_ type: String, ts: String, id: String? = nil, output: Int = 0, model: String = "claude-opus-5-5") -> String {
        if type == "assistant" {
            let idPart = id.map { "\"id\":\"\($0)\"," } ?? ""
            return "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"timestamp\":\"\(ts)\",\"message\":{\(idPart)\"model\":\"\(model)\",\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output)}}}"
        }
        return "{\"type\":\"\(type)\",\"sessionId\":\"s1\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"
    }

    func testClaudeTimingRunsFromPreviousLineToLastBlockOfSameMessage() throws {
        let url = try write([
            claudeLine("user", ts: "2026-10-13T02:00:00.000Z"),                                   // 请求 1 发出
            claudeLine("assistant", ts: "2026-10-13T02:00:03.000Z", id: "m1", output: 120),       // 思考块
            claudeLine("assistant", ts: "2026-10-13T02:00:04.000Z", id: "m1", output: 120),       // 工具调用块（同一回复）
            claudeLine("user", ts: "2026-10-13T02:00:09.000Z"),                                   // 工具结果 = 请求 2 发出
            claudeLine("assistant", ts: "2026-10-13T02:00:11.000Z", id: "m2", output: 80),
            "{\"type\":\"custom-title\",\"sessionId\":\"s1\",\"customTitle\":\"无时间戳行不影响\"}",
            claudeLine("user", ts: "2026-10-13T02:01:00.000Z"),
            claudeLine("assistant", ts: "2026-10-13T03:00:00.000Z", id: "m3", output: 999),      // 1 小时：电脑睡眠，剔除
        ], to: "s1.jsonl")
        let details = ClaudeDetailScanner.detailRecords(url: url, providerId: "claude-code", attachSource: false)
        XCTAssertEqual(details.reduce(0) { $0 + $1.output }, 120 + 80 + 999, "计入的 token 不变：同一回复多行只计一次")
        XCTAssertEqual(sum(details), GenerationTiming(output: 120 + 80, millis: 4_000 + 2_000))
        XCTAssertTrue(details.allSatisfy { $0.timing != nil }, "新口径解析的明细一律带 timing（可为 0）")
    }

    /// 真机实测的两个坑：Qoder 的 fork 先写一行不带 usage 的同 id 行（同一时刻）；旧版客户端首行 output 是流式临时值。
    func testClaudeTimingSkipsUsagelessFirstRowAndUsesFinalOutput() throws {
        let noUsage = "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"timestamp\":\"2026-08-14T09:01:44.903Z\",\"message\":{\"id\":\"q1\",\"model\":\"bailian/deepseek-v4-flash-tp\"}}"
        let url = try write([
            claudeLine("user", ts: "2026-08-14T09:01:40.351Z"),
            noUsage,
            claudeLine("assistant", ts: "2026-08-14T09:01:44.903Z", id: "q1", output: 123, model: "bailian/deepseek-v4-flash-tp"),
            claudeLine("user", ts: "2026-08-14T09:02:00.000Z"),
            claudeLine("assistant", ts: "2026-08-14T09:02:01.000Z", id: "c1", output: 6, model: "claude-sonnet-4-6"),
            claudeLine("assistant", ts: "2026-08-14T09:02:05.000Z", id: "c1", output: 252, model: "claude-sonnet-4-6"),
        ], to: "q.jsonl")
        let details = ClaudeDetailScanner.detailRecords(url: url, providerId: "qoder-cli", attachSource: false)
        let q = details.first { $0.model == "bailian/deepseek-v4-flash-tp" }!
        XCTAssertEqual(q.timing, GenerationTiming(output: 123, millis: 4_552), "开始 = 不带 usage 那行之前的用户消息，不是同一时刻的自己")
        let c = details.first { $0.model == "claude-sonnet-4-6" }!
        XCTAssertEqual(c.output, 6, "计入的 token 口径不变（仍取首行，本版不改）")
        XCTAssertEqual(c.timing, GenerationTiming(output: 252, millis: 5_000), "速度用最终值，不用首行临时值")
    }

    // MARK: - Codex：用量事件晚于工具结果落盘，不能当「回答完」

    private func codexUsage(_ input: Int, _ output: Int) -> String {
        "{\"input_tokens\":\(input),\"cached_input_tokens\":0,\"output_tokens\":\(output),\"reasoning_output_tokens\":0,\"total_tokens\":\(input + output)}"
    }

    private func codexTokenCount(_ ts: String, total: (Int, Int), last: (Int, Int)) -> String {
        "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(codexUsage(total.0, total.1)),\"last_token_usage\":\(codexUsage(last.0, last.1))}}}"
    }

    private func codexItem(_ ts: String, _ type: String, role: String? = nil) -> String {
        let r = role.map { ",\"role\":\"\($0)\"" } ?? ""
        return "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"\(type)\"\(r)}}"
    }

    func testCodexRealRefreshTimesFromInputToLastGeneratedItem() async throws {
        let home = dir.appendingPathComponent(".codex")
        let id = "019f0000-0000-7000-8000-000000000001"
        _ = try write([
            "{\"timestamp\":\"2026-10-13T06:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\"vscode\"}}",
            "{\"timestamp\":\"2026-10-13T06:00:00.000Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6-astra\"}}",
            "{\"timestamp\":\"2026-10-13T06:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}",
            codexItem("2026-10-13T06:00:01.000Z", "message", role: "user"),                 // 请求 1 发出
            codexItem("2026-10-13T06:00:07.000Z", "reasoning"),
            codexItem("2026-10-13T06:00:09.000Z", "function_call"),                         // 请求 1 回答完
            "{\"timestamp\":\"2026-10-13T06:00:09.100Z\",\"type\":\"token_usage_record\",\"payload\":{}}",
            codexItem("2026-10-13T06:00:15.000Z", "function_call_output"),                  // 工具跑了 6 秒 = 请求 2 发出
            codexTokenCount("2026-10-13T06:00:15.001Z", total: (1_000, 100), last: (1_000, 100)),   // 晚到的用量事件
            codexItem("2026-10-13T06:00:18.000Z", "reasoning"),
            codexItem("2026-10-13T06:00:20.000Z", "message", role: "assistant"),            // 请求 2 回答完
            codexTokenCount("2026-10-13T06:00:20.050Z", total: (2_500, 300), last: (1_500, 200)),
            codexTokenCount("2026-10-13T06:00:21.000Z", total: (2_500, 300), last: (1_500, 200)),   // 重复事件：不计 token 也不计时
        ], to: ".codex/sessions/2026/10/13/rollout-2026-10-13T14-00-00-\(id).jsonl")

        let cache = FileMtimeCache()
        let records = try await CodexProvider(codexHome: home, cache: cache, detailScanner: CodexDetailScanner())
            .fetchDailyRecords()
        let details = await cache.details(forProvider: "codex")
        XCTAssertEqual(records.reduce(0) { $0 + $1.token }, 2_800, "主列表 token 不受影响")
        XCTAssertEqual(details.reduce(0) { $0 + $1.tokens.total }, 2_800, "列表 = 明细")
        // 请求 1：06:00:01 → 06:00:09 = 8 秒（不含后面 6 秒工具执行）；请求 2：06:00:15 → 06:00:20 = 5 秒
        XCTAssertEqual(sum(details), GenerationTiming(output: 100 + 200, millis: 8_000 + 5_000))

        let speed = LedgerDetailAggregator.aggregate(providerId: "codex", details: details, window: .all)
            .models.first!.tokensPerSecond!
        XCTAssertEqual(speed, 300.0 / 13, accuracy: 0.001)
    }

    // MARK: - 千问办公 / Qoder CLI segments

    func testSegmentPairsRequestStartedWithCompleted() throws {
        let url = try write([
            "{\"ts\":\"2026-09-12T17:08:58.000+08:00\",\"type\":\"model.request.started\",\"request_id\":\"r1\",\"data\":{}}",
            "{\"ts\":\"2026-09-12T17:09:02.500+08:00\",\"type\":\"model.response.completed\",\"request_id\":\"r1\",\"data\":{\"model\":\"pro\",\"input_tokens\":100,\"output_tokens\":45,\"cache_read_input_tokens\":0}}",
            "{\"ts\":\"2026-09-12T17:09:10.000+08:00\",\"type\":\"model.response.completed\",\"request_id\":\"r2\",\"data\":{\"model\":\"pro\",\"input_tokens\":100,\"output_tokens\":30,\"cache_read_input_tokens\":0}}",
        ], to: "logs/sessions/sess-1/segments/a.jsonl")
        let events = try QwenWorkSegmentParser.parseFile(url: url)
        XCTAssertEqual(events.map(\.genMillis), [4_500, nil], "r2 没有 started → 不计时，但 token 照计")
        XCTAssertEqual(events[0].timing, GenerationTiming(output: 45, millis: 4_500))
        XCTAssertEqual(events[1].timing, GenerationTiming())
    }

    // MARK: - WorkBuddy：沿父链跳过思考行

    func testWorkBuddyWalksParentChainPastReasoning() throws {
        func line(_ id: String, parent: String?, ts: Int64, role: String?, type: String = "message", usage: Bool = false) -> String {
            let p = parent.map { "\"parentId\":\"\($0)\"," } ?? ""
            let r = role.map { "\"role\":\"\($0)\"," } ?? ""
            let pd = usage ? ",\"providerData\":{\"model\":\"auto\",\"rawUsage\":{\"prompt_tokens\":1000,\"completion_tokens\":300}}" : ""
            return "{\"id\":\"\(id)\",\(p)\(r)\"type\":\"\(type)\",\"sessionId\":\"wb\",\"timestamp\":\(ts)\(pd)}"
        }
        let url = try write([
            line("u1", parent: nil, ts: 1_780_246_596_000, role: "user"),
            line("r1", parent: "u1", ts: 1_780_246_609_651, role: nil, type: "reasoning"),
            line("a1", parent: "r1", ts: 1_780_246_609_657, role: "assistant", usage: true),
        ], to: "wb/s.jsonl")
        let rows = WorkBuddyDetailScanner.parse(url: url).rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].genMillis, 13_657, "开始 = 用户消息，不是只差 6 毫秒的思考行")
    }

    // MARK: - OpenCode：data.time.created → completed

    func testOpenCodeReadsCompletedTime() throws {
        let path = dir.appendingPathComponent("opencode.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        exec("CREATE TABLE session (id text PRIMARY KEY, title text NOT NULL, parent_id text);")
        exec("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, data text NOT NULL);")
        for (id, created, completed) in [("m1", 1_790_226_734_523, "1790226761886"), ("m2", 1_790_226_800_000, "null")] {
            let data = "{\"role\":\"assistant\",\"modelID\":\"mimo\",\"time\":{\"created\":\(created),\"completed\":\(completed)},\"tokens\":{\"input\":10,\"output\":600,\"reasoning\":16,\"cache\":{\"read\":0,\"write\":0}}}"
            exec("INSERT INTO message VALUES ('\(id)', 's', \(created), '\(data)');")
        }
        sqlite3_close(db)
        let rows = OpenCodeDB.load(dbPath: path).messages.sorted { $0.time < $1.time }
        XCTAssertEqual(rows.map(\.genMillis), [27_363, nil], "回复没写完（completed 缺失）→ 不计时")
        XCTAssertEqual(rows[0].tokens.output, 616, "output 含思考，计时用同一个数")
    }

    // MARK: - Qoder IDE：同会话上一条消息的时间

    func testQoderIdeUsesPreviousMessageInSameSession() throws {
        let path = dir.appendingPathComponent("local.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        exec("CREATE TABLE chat_message (id text, session_id text, role text, token_info text, model_info text, gmt_create text);")
        exec("CREATE TABLE chat_session (session_id text, session_title text, project_name text);")
        let ti = "{\"prompt_tokens\":23912,\"completion_tokens\":35,\"cached_tokens\":0}"
        exec("""
            INSERT INTO chat_message VALUES
              ('1','a','user','','','1782355257116'),
              ('2','a','assistant','\(ti)','{"model_key":"qmodel"}','1782355260307'),
              ('3','b','assistant','\(ti)','{"model_key":"qmodel"}','1782355260000');
            """)
        sqlite3_close(db)
        let rows = QoderIdeDetailScanner.query(dbPath: path).sorted { $0.sessionId < $1.sessionId }
        XCTAssertEqual(rows.map(\.genMillis), [3_191, nil], "会话 b 的第一条没有上一条 → 不计时")
    }
}
