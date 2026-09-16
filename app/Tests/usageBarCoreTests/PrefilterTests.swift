import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// 解析预筛回归锁（0709 spec R3，v0.3.30）。
///
/// 红线：预筛判据必须「目标行必然包含 needle」——只允许误放行（内容行恰好含关键字 → 多解析一行,
/// 由消费方结构 guard 兜住），**绝不允许漏掉目标行**。两条路径（needle on/off）计量结果必须逐条一致。
final class PrefilterTests: XCTestCase {

    private func writeTemp(_ name: String, _ lines: [String]) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefilter-\(name)-\(UUID().uuidString).jsonl")
        try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - JSONLReader 层

    /// needle 命中的行照常回调；不含 needle 的行被跳过；空 needle（nil）= 全部回调。
    func testNeedleSkipsNonMatchingLines() {
        let url = writeTemp("reader", [
            #"{"kind":"a","payload":"token_count"}"#,
            #"{"kind":"b","payload":"nothing"}"#,
            #"{"kind":"c","note":"聊聊 token_count 这个词"}"#,   // 内容里含关键字 → 误放行（允许）
            #"not valid json token_count"#,                        // 命中但非法 JSON → 静默跳过
        ])
        var kinds: [String] = []
        try? JSONLReader.forEachLine(at: url, lineNeedle: "token_count") { obj in
            kinds.append(obj["kind"] as? String ?? "?")
        }
        XCTAssertEqual(kinds, ["a", "c"], "命中行(含误放行)都要回调，未命中行必须跳过")

        var all: [String] = []
        try? JSONLReader.forEachLine(at: url) { obj in all.append(obj["kind"] as? String ?? "?") }
        XCTAssertEqual(all, ["a", "b", "c"], "无 needle = 不预筛，行为与旧版完全一致")
    }

    /// 尾行无换行符时预筛照常生效（forEachLine 的尾行分支）。
    func testNeedleOnUnterminatedLastLine() {
        let url = writeTemp("tail", [#"{"kind":"x"}"#, #"{"kind":"y","m":"token_count"}"#])
        var kinds: [String] = []
        try? JSONLReader.forEachLine(at: url, lineNeedle: "token_count") { obj in
            kinds.append(obj["kind"] as? String ?? "?")
        }
        XCTAssertEqual(kinds, ["y"])
    }

    // MARK: - Claude 对拍（合成 fixture）

    /// ⛔ 口径红线：预筛开/关两条路径的解析结果必须逐条一致。
    /// fixture 覆盖：正常 assistant 行 / 内容里含 `"type":"assistant"` 文本的用户行（误放行）/
    /// 流式重复 message.id（去重逻辑）/ 无关行。
    func testClaudeParityWithSyntheticFixture() throws {
        let url = writeTemp("claude", [
            #"{"type":"assistant","timestamp":"2026-08-11T10:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":100}}}"#,
            // 用户行,内容里恰好含 needle 文本 → 误放行后被 type guard 排除,不计数
            #"{"type":"user","timestamp":"2026-08-11T10:01:00.000Z","message":{"content":"日志里 \"type\":\"assistant\" 是什么"}}"#,
            // 同 message.id 的流式重复行 → 只计一次
            #"{"type":"assistant","timestamp":"2026-08-11T10:02:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":100}}}"#,
            #"{"type":"assistant","timestamp":"2026-08-11T10:03:00.000Z","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            #"{"type":"summary","summary":"与统计无关的行"}"#,
        ])
        let withNeedle = try ClaudeTranscriptParser.parse(url: url, classify: { _ in "claude-code" })
        let without = try ClaudeTranscriptParser.parse(url: url, classify: { _ in "claude-code" }, lineNeedle: nil)
        let sortKey: (FileDailyRecord, FileDailyRecord) -> Bool = { "\($0.provider)|\($0.date)" < "\($1.provider)|\($1.date)" }
        XCTAssertEqual(withNeedle.sorted(by: sortKey), without.sorted(by: sortKey), "预筛开/关结果必须一致")
        XCTAssertEqual(withNeedle.count, 1)
        XCTAssertEqual(withNeedle[0].token, 135 + 3, "m1 计一次(135) + m2(3)；重复行与误放行不计")
        XCTAssertEqual(withNeedle[0].cachedToken, 100)
    }

    // MARK: - Codex 对拍（合成 fixture）

    func testCodexParityWithSyntheticFixture() {
        let url = writeTemp("codex", [
            #"{"timestamp":"2026-08-11T10:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":6,"reasoning_output_tokens":0,"total_tokens":16}},"rate_limits":{}}}"#,
            #"{"timestamp":"2026-08-11T10:00:30.000Z","payload":{"type":"agent_message","message":"上游把 token_count 改了"}}"#,
            #"{"timestamp":"2026-08-11T10:01:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":8,"output_tokens":12,"reasoning_output_tokens":0,"total_tokens":32}},"rate_limits":{}}}"#,
            #"{"timestamp":"2026-08-11T10:02:00.000Z","payload":{"type":"user_message","message":"hello"}}"#,
        ])
        let p = CodexProvider()
        let withNeedle = p.parseRawEvents(url: url)
        let without = p.parseRawEvents(url: url, lineNeedle: nil)
        XCTAssertEqual(withNeedle.count, without.count, "预筛开/关事件数必须一致")
        XCTAssertEqual(withNeedle.map(\.total.total), without.map(\.total.total))
        XCTAssertEqual(withNeedle.map(\.total.cached), without.map(\.total.cached))
        XCTAssertEqual(withNeedle.count, 2)
    }

    // MARK: - 真机提速计时（环境变量门控，手动跑；⚠️ 必须 `-c release` 跑才是真实数字）

    /// `USAGEBAR_PREFILTER_SPEED=1 swift test -c release --filter testPrefilterSpeed`
    /// debug 模式瓶颈在未优化的逐字节循环（两条路径同样付），会严重低估预筛收益。
    func testPrefilterSpeed() throws {
        guard ProcessInfo.processInfo.environment["USAGEBAR_PREFILTER_SPEED"] == "1" else {
            throw XCTSkip("提速计时需显式开启 USAGEBAR_PREFILTER_SPEED=1")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        func timeIt(_ block: () -> Void) -> Double {
            let t0 = Date(); block(); return Date().timeIntervalSince(t0)
        }

        let claudeFiles = JSONLReader.findFiles(under: home.appendingPathComponent(".claude/projects")) {
            $0.pathExtension == "jsonl"
        }
        let cNew = timeIt { for u in claudeFiles { _ = try? ClaudeTranscriptParser.parse(url: u, classify: { _ in "c" }) } }
        let cOld = timeIt { for u in claudeFiles { _ = try? ClaudeTranscriptParser.parse(url: u, classify: { _ in "c" }, lineNeedle: nil) } }

        let codexFiles = JSONLReader.findFiles(under: home.appendingPathComponent(".codex/sessions")) {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
        }
        let p = CodexProvider()
        let xNew = timeIt { for u in codexFiles { _ = p.parseRawEvents(url: u) } }
        let xOld = timeIt { for u in codexFiles { _ = p.parseRawEvents(url: u, lineNeedle: nil) } }

        print(String(format: "[speed] Claude(%d文件): 预筛 %.1fs vs 全解析 %.1fs = %.1fx",
                     claudeFiles.count, cNew, cOld, cOld / max(cNew, 0.001)))
        print(String(format: "[speed] Codex(%d文件): 预筛 %.1fs vs 全解析 %.1fs = %.1fx",
                     codexFiles.count, xNew, xOld, xOld / max(xNew, 0.001)))
    }

    // MARK: - 真机全量对拍（环境变量门控，手动跑）

    /// `USAGEBAR_REAL_DATA_PARITY=1 swift test --filter testRealDataParity`
    /// 扫本机全部真实历史文件，needle on/off 双路径逐文件比对。慢（双份全量解析），CI/常规不跑。
    func testRealDataParity() throws {
        guard ProcessInfo.processInfo.environment["USAGEBAR_REAL_DATA_PARITY"] == "1" else {
            throw XCTSkip("真机对拍需显式开启 USAGEBAR_REAL_DATA_PARITY=1")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Claude Code transcripts
        let claudeRoot = home.appendingPathComponent(".claude/projects")
        let claudeFiles = JSONLReader.findFiles(under: claudeRoot) { $0.pathExtension == "jsonl" }
        var claudeMismatch: [String] = []
        for url in claudeFiles {
            let a = (try? ClaudeTranscriptParser.parse(url: url, classify: { _ in "claude-code" })) ?? []
            let b = (try? ClaudeTranscriptParser.parse(url: url, classify: { _ in "claude-code" }, lineNeedle: nil)) ?? []
            let k: (FileDailyRecord, FileDailyRecord) -> Bool = { "\($0.provider)|\($0.date)" < "\($1.provider)|\($1.date)" }
            if a.sorted(by: k) != b.sorted(by: k) { claudeMismatch.append(url.lastPathComponent) }
        }
        XCTAssertTrue(claudeMismatch.isEmpty, "Claude 对拍不一致: \(claudeMismatch)")

        // Codex rollouts
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let codexFiles = JSONLReader.findFiles(under: codexRoot) {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
        }
        let p = CodexProvider()
        var codexMismatch: [String] = []
        for url in codexFiles {
            let a = p.parseRawEvents(url: url)
            let b = p.parseRawEvents(url: url, lineNeedle: nil)
            if a.map({ "\($0.ts.timeIntervalSince1970)|\($0.total.total)|\($0.total.cached)" })
                != b.map({ "\($0.ts.timeIntervalSince1970)|\($0.total.total)|\($0.total.cached)" }) {
                codexMismatch.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(codexMismatch.isEmpty, "Codex 对拍不一致: \(codexMismatch)")
        print("[parity] Claude \(claudeFiles.count) 文件 / Codex \(codexFiles.count) 文件 全部一致")
    }
}
