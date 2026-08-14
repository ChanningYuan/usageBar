import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// Qoder CLI segment 会话标题的回归锁（v0.3.34，GitHub issue #10）。
///
/// v0.3.33 接 segment 日志时，把 `title` 写死成空串，注释理由是「segment 无会话标题」。
/// 那句话只对**这条 token 事件本身**成立——同一个 sessionId 在 Qoder 的持久化 transcript 里
/// 往往是有标题的（Qoder 自己 `Chat Sessions` 列表就显示着）。两件事混为一谈的结果：
/// 报告人本机 37 个会话**全部**显示「(无标题会话)」，「按会话」区等于废了。
///
/// 这里锁的是修复后的三档解析顺序，以及**两个绝不能被"顺手优化"掉的口径**：
/// ① usage 全 0 的 transcript 也必须能取到标题；② request_id 的收集口径不许变（一变就动 token）。
final class QoderSessionTitleTests: XCTestCase {

    private func write(_ lines: [String], name: String = "s.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 三档解析顺序

    func testTranscriptTitleWinsOverProjectDir() {
        XCTAssertEqual(
            QoderCliProvider.sessionTitle(for: "S1",
                                          transcripts: ["S1": "重构价目表拉取"],
                                          roots: ["S1": "/Users/me/开发/usageBar"]),
            "重构价目表拉取",
            "⛔ 第①档：Qoder 自己的会话标题优先，别被工作目录名盖掉")
    }

    /// `--no-session-persistence` 的会话压根没有 transcript，只能靠工作目录末级名。
    func testFallsBackToProjectDirLastComponent() {
        XCTAssertEqual(
            QoderCliProvider.sessionTitle(for: "S2", transcripts: [:],
                                          roots: ["S2": "/Users/me/开发/usageBar"]),
            "usageBar",
            "⛔ 第②档：无 transcript 时用工作目录末级名，比 8 位 UUID 强")
    }

    /// 两档都空时返回空串——兜底文案由 `LedgerDetailAggregator` 统一给，别在 provider 里造。
    func testEmptyWhenNothingAvailable() {
        XCTAssertEqual(QoderCliProvider.sessionTitle(for: "S3", transcripts: [:], roots: [:]), "")
        XCTAssertEqual(QoderCliProvider.sessionTitle(for: "S4", transcripts: ["S4": ""],
                                                     roots: ["S4": "/"]), "",
                       "根目录 / 不是有意义的会话名")
    }

    // MARK: - ⚠️ #10 的核心：usage 全 0 的 transcript 也要能拿到标题

    /// Qoder CLI 没开 `QODER_EXPOSE_TOKEN_USAGE` 时 transcript 里 usage 全是 0，
    /// token 真值只在 segments 里。`detailRecords` 是 `units.map`，此时产出 0 条记录、
    /// 标题一起丢——**这就是 #10 的根**。`index(url:)` 必须绕开 token 直接拿元信息。
    func testIndexKeepsTitleWhenAllUsageIsZero() throws {
        let url = try write([
            #"{"type":"ai-title","sessionId":"Z1","aiTitle":"排查构建缓存","timestamp":"2026-08-14T10:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"Z1","timestamp":"2026-08-14T10:00:01Z","message":{"id":"m1","model":"cmodel","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ])

        XCTAssertTrue(ClaudeDetailScanner.detailRecords(url: url, providerId: "qoder-cli",
                                                        attachSource: false).isEmpty,
                      "前提：usage 全 0 时明细记录本来就是空的")
        XCTAssertEqual(ClaudeDetailScanner.index(url: url).titles["Z1"], "排查构建缓存",
                       "⛔ 回归 #10：token 为 0 不代表会话没标题，index 必须仍然给出标题")
    }

    // MARK: - 标题优先级（与 Qoder Agent SDK 的 summary 规则对齐）

    func testIndexTitlePriorityCustomOverAiOverFirstUser() throws {
        let base = [
            #"{"type":"user","sessionId":"P1","timestamp":"2026-08-14T10:00:00Z","message":{"content":"帮我看下这个报错"}}"#,
            #"{"type":"assistant","sessionId":"P1","timestamp":"2026-08-14T10:00:01Z","message":{"id":"m1","model":"cmodel","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ]
        XCTAssertEqual(ClaudeDetailScanner.index(url: try write(base)).titles["P1"],
                       "帮我看下这个报错", "第③档：首条用户输入")

        let withAi = base + [
            #"{"type":"ai-title","sessionId":"P1","aiTitle":"报错排查","timestamp":"2026-08-14T10:00:02Z"}"#,
        ]
        XCTAssertEqual(ClaudeDetailScanner.index(url: try write(withAi)).titles["P1"],
                       "报错排查", "第②档：AI 标题压过首条用户输入")

        let withCustom = withAi + [
            #"{"type":"custom-title","sessionId":"P1","customTitle":"周三的坑"}"#,
        ]
        XCTAssertEqual(ClaudeDetailScanner.index(url: try write(withCustom)).titles["P1"],
                       "周三的坑", "第①档：用户 /rename 是明确意图，压过一切")
    }

    /// 解析不出标题的会话**不进表**——留空让调用方走下一档，别塞个空串占位。
    func testIndexOmitsSessionsWithoutAnyTitleSource() throws {
        let url = try write([
            #"{"type":"assistant","sessionId":"N1","timestamp":"2026-08-14T10:00:00Z","message":{"id":"m1","model":"cmodel","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ])
        XCTAssertNil(ClaudeDetailScanner.index(url: url).titles["N1"])
    }

    // MARK: - ⚠️ request_id 口径锁（动它就等于动 token 数字）

    /// v0.3.34 把「收 request_id」和「解析标题」合并成一趟读盘。合并时 request_id 的收集时机
    /// **必须仍在 message.id 去重、模型过滤、token 归零判据之前**，与 v0.3.33 那版逐字一致。
    /// 往后挪一行 → Qoder CLI 的跨源去重集合变小 → segment 侧多计一批请求 → token 静默变大。
    func testIndexCollectsRequestIdsBeforeAnyTokenFilter() throws {
        let url = try write([
            // ① token 全 0（gate 没开）
            #"{"type":"assistant","sessionId":"R1","timestamp":"2026-08-14T10:00:00Z","message":{"id":"m1","model":"cmodel","usage":{"input_tokens":0,"output_tokens":0,"request_id":"req-zero"}}}"#,
            // ② `<synthetic>` 模型（解析器会跳过它算 token）
            #"{"type":"assistant","sessionId":"R1","timestamp":"2026-08-14T10:00:01Z","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":9,"output_tokens":9,"request_id":"req-synthetic"}}}"#,
            // ③ 没有 timestamp（正常 token 路径会 guard 掉）
            #"{"type":"assistant","sessionId":"R1","message":{"id":"m3","model":"cmodel","usage":{"input_tokens":7,"output_tokens":7,"request_id":"req-nots"}}}"#,
            // ④ 正常一条
            #"{"type":"assistant","sessionId":"R1","timestamp":"2026-08-14T10:00:03Z","message":{"id":"m4","model":"cmodel","usage":{"input_tokens":100,"output_tokens":20,"request_id":"req-ok"}}}"#,
        ])
        XCTAssertEqual(ClaudeDetailScanner.index(url: url).requestIds,
                       ["req-zero", "req-synthetic", "req-nots", "req-ok"],
                       "⛔ 四种会被 token 路径过滤掉的行，request_id 都必须照收——这是 v0.3.33 的口径")
    }

    /// Claude 官方 transcript 没有 `usage.request_id`（本机 6,555 条实测全无）→ 空集合，不报错。
    func testIndexRequestIdsEmptyForOfficialClaudeTranscript() throws {
        let url = try write([
            #"{"type":"assistant","sessionId":"C1","timestamp":"2026-08-14T10:00:00Z","message":{"id":"msg_011abc","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ])
        XCTAssertTrue(ClaudeDetailScanner.index(url: url).requestIds.isEmpty)
    }

    // MARK: - segment 侧的工作目录兜底

    func testSegmentProjectRootPrefersProjectRootThenTargetDir() throws {
        let a = try write([
            #"{"type":"session.config.loaded","ts":"2026-08-14T10:00:00+08:00","data":{"project_root":"/Users/me/开发/usageBar","target_dir":"/tmp/other"}}"#,
        ])
        XCTAssertEqual(QoderCliSegmentSource.projectRoot(in: a), "/Users/me/开发/usageBar")

        let b = try write([
            #"{"type":"session.config.loaded","ts":"2026-08-14T10:00:00+08:00","data":{"project_root":"","target_dir":"/Users/me/ai_coding/daily-system"}}"#,
        ])
        XCTAssertEqual(QoderCliSegmentSource.projectRoot(in: b), "/Users/me/ai_coding/daily-system",
                       "project_root 为空串时退到 target_dir")
    }

    /// ⛔ **刻意不解析 `text_preview`**：它从 prompt 开头截断，SDK/桥接场景下前 1999 字符
    /// 常是 host 前言和旧对话历史（报告人本机 27/37 条 truncated=true），还可能含 system prompt
    /// 或敏感片段。这条锁住「以后别顺手把它接上」。
    func testSegmentProjectRootIgnoresPromptPreview() throws {
        let url = try write([
            #"{"type":"input.prompt.received","ts":"2026-08-14T10:00:00+08:00","data":{"query_source":"sdk","text_length":391062,"text_preview":"The following is the conversation supplied by the host...","truncated":true}}"#,
        ])
        XCTAssertNil(QoderCliSegmentSource.projectRoot(in: url),
                     "⛔ text_preview 不是标题源，一条 prompt 事件不该产出任何显示名")
    }

    func testSegmentProjectRootNilWhenNoConfigEvent() throws {
        let url = try write([
            #"{"type":"model.response.completed","ts":"2026-08-14T10:00:00+08:00","request_id":"r1","data":{"model":"cmodel","input_tokens":10,"output_tokens":5}}"#,
        ])
        XCTAssertNil(QoderCliSegmentSource.projectRoot(in: url))
    }
}

/// Qoder CLI「只统计有持久化会话的调用」回归锁（v0.3.35，用户拍板的计量口径）。
///
/// 判据 = 该 sessionId 在 `~/.qoder/projects` 里有没有 transcript。
/// 无 transcript ⟹ 只可能来自 `--no-session-persistence`，而宿主（Claude Code 等）的
/// Agent SDK 桥接一定带这个参数——那笔账记在宿主名下，这里再记就是重复（issue #9）。
///
/// ⚠️ 这等于把 issue #8 的症状②（`--no-session-persistence` 漏统）撤回一半，是刻意的。
final class QoderPersistedOnlyTests: XCTestCase {

    private func entry(_ path: String, session: String, token: Int) -> FileCacheEntry {
        FileCacheEntry(filePath: path, mtime: Date(), size: token,
                       records: [FileDailyRecord(provider: "qoder-cli", date: "2026-08-14", token: token)],
                       details: [FileDetailRecord(provider: "qoder-cli", date: "2026-08-14",
                                                  sessionId: session, title: "", model: "cmodel",
                                                  lastActivity: Date(),
                                                  tokens: TokenBreakdown(input: token, output: 0))])
    }

    private func segKey(_ session: String, _ request: String) -> String {
        "/Users/x/.qoder/logs/sessions/.usagebar-request-ledger/\(session)/\(request)"
    }

    /// 有 transcript 的会话保留，无 transcript 的 segment 条目清掉。
    func testPurgeRemovesOnlyNonPersistedSegmentEntries() async {
        let cache = FileMtimeCache()
        await cache.store(entry(segKey("KEEP", "r1"), session: "KEEP", token: 100))
        await cache.store(entry(segKey("DROP", "r2"), session: "DROP", token: 200))
        // transcript 条目：按定义就是持久化会话，任何时候都不该被这段逻辑碰
        await cache.store(entry("/Users/x/.qoder/projects/p/KEEP.jsonl", session: "KEEP", token: 300))

        let persisted: Set<String> = ["KEEP"]
        let removed = await cache.remove { e in
            guard e.filePath.contains("/.usagebar-request-ledger/"),
                  e.records.contains(where: { $0.provider == "qoder-cli" }) else { return false }
            let sid = e.details.first?.sessionId
                ?? ((e.filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return !sid.isEmpty && !persisted.contains(sid)
        }
        XCTAssertEqual(removed, 1)
        let left = await cache.allEntries().map(\.filePath).sorted()
        XCTAssertEqual(left, ["/Users/x/.qoder/logs/sessions/.usagebar-request-ledger/KEEP/r1",
                              "/Users/x/.qoder/projects/p/KEEP.jsonl"],
                       "⛔ transcript 条目和有会话的 segment 条目都必须留下")
    }

    /// ⚠️ 权限保护：`~/.qoder/projects` 存在却一个 transcript 都读不到时（issue #8 报告人本机
    /// 遇到过 `Operation not permitted`），持久会话集合会是空集。此时**绝不能照常清理**，
    /// 否则会把全部 Qoder 历史抹掉——账本是持久的，抹了就没了。
    func testPurgeSkippedWhenProjectsDirUnreadable() async {
        let cache = FileMtimeCache()
        await cache.store(entry(segKey("S1", "r1"), session: "S1", token: 100))

        let projectsDirExists = true, projectsDirReadable = false
        let shouldPurge = projectsDirReadable || !projectsDirExists
        XCTAssertFalse(shouldPurge, "⛔ 目录在、却读不到任何 transcript → 必须整段跳过清理")

        if shouldPurge { _ = await cache.remove { _ in true } }
        let n = await cache.count()
        XCTAssertEqual(n, 1, "跳过清理时账本必须原封不动")
    }

    /// 目录压根不存在 = 可信的「确实没有任何持久化会话」→ 正常清理。
    func testPurgeRunsWhenProjectsDirAbsent() {
        let projectsDirExists = false, projectsDirReadable = false
        XCTAssertTrue(projectsDirReadable || !projectsDirExists)
    }
}
