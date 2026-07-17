import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// 会话标题 + 通用扫描器回归锁（v0.3.23）。
///
/// v0.3.22 发出去后被用户一眼看出：新 provider 的会话名显示成 sessionId 前缀（`b7a01030-b21`），
/// 而数据里明明有可读标题。顺藤摸瓜还揪出一个更严重的：`ClaudeDetailScanner.aggregate` 里
/// 残留着 `guard providerId == "claude-code"`，导致复用它的 **Cowork / Qoder CLI / Qoder Work
/// 三个详情页点进去全是空的**。
///
/// 教训：把扫描器"参数化"时，**文件源和聚合逻辑是两处**，只改一处等于没改。
final class SessionTitleTests: XCTestCase {

    // MARK: - WorkBuddy 标题提取

    /// `content` 是**块数组**（不是字符串），且首块常是 `<system-reminder>` 系统注入 —— 必须跳过。
    /// v0.3.22 首版按字符串读 → 永远读不到 → 标题退化成 sessionId 前缀。
    func testWorkBuddyUserTextSkipsSystemInjectedBlocks() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "<system-reminder>\nUser environment — Timezone: Asia/Shanghai…"],
            ["type": "text", "text": "帮我看下这个报错"],
        ]
        XCTAssertEqual(WorkBuddyDetailScanner.plainUserText(content), "帮我看下这个报错",
                       "⛔ 回归：`<system-reminder>` 注入块被当成用户输入了")
    }

    func testWorkBuddyUserTextHandlesPlainStringToo() {
        XCTAssertEqual(WorkBuddyDetailScanner.plainUserText("你好"), "你好")
    }

    func testWorkBuddyUserTextRejectsOnlyInjectedBlocks() {
        let content: [[String: Any]] = [["type": "text", "text": "<command-name>/clear</command-name>"]]
        XCTAssertNil(WorkBuddyDetailScanner.plainUserText(content),
                     "全是尖括号包裹的系统块时应返回 nil，让上层退到下一档标题源")
    }

    // MARK: - /rename 手动改名（custom-title）

    /// v0.3.26：Claude Code `/rename` 写入的是 `{"type":"custom-title","customTitle":"..."}`，
    /// 与 AI 自动标题（`ai-title`）是**两个字段**。此前扫描器只认 ai-title → 用户改名后
    /// usageBar 会话列表纹丝不动。手动命名是用户明确意图，优先级必须压过自动标题。
    func testCustomTitleFromRenameBeatsAiTitle() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageBar-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lines = [
            #"{"type":"user","sessionId":"S1","timestamp":"2026-07-16T03:00:00.000Z","message":{"role":"user","content":"第一句用户输入"}}"#,
            #"{"type":"assistant","sessionId":"S1","timestamp":"2026-07-16T03:00:05.000Z","message":{"id":"msg_t1","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"ai-title","aiTitle":"AI 自动起的标题","sessionId":"S1","timestamp":"2026-07-16T03:00:10.000Z"}"#,
            #"{"type":"custom-title","customTitle":"第一次改名","sessionId":"S1"}"#,
            #"{"type":"custom-title","customTitle":"第二次改名","sessionId":"S1"}"#,
        ]
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let detail = await ClaudeDetailScanner().detail(providerId: "claude-code", root: dir, window: .all)
        XCTAssertEqual(detail.sessions.count, 1)
        XCTAssertEqual(detail.sessions.first?.title, "第二次改名",
                       "⛔ 回归：/rename 的 custom-title 没生效（应压过 ai-title，且多次改名取最后一条）")
    }

    /// 没有 rename 时行为不变：ai-title → 首条用户输入 的旧优先级不受影响。
    func testAiTitleStillWinsWithoutCustomTitle() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageBar-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lines = [
            #"{"type":"user","sessionId":"S2","timestamp":"2026-07-16T03:00:00.000Z","message":{"role":"user","content":"第一句用户输入"}}"#,
            #"{"type":"assistant","sessionId":"S2","timestamp":"2026-07-16T03:00:05.000Z","message":{"id":"msg_t2","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"ai-title","aiTitle":"AI 自动起的标题","sessionId":"S2","timestamp":"2026-07-16T03:00:10.000Z"}"#,
        ]
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)

        let detail = await ClaudeDetailScanner().detail(providerId: "claude-code", root: dir, window: .all)
        XCTAssertEqual(detail.sessions.first?.title, "AI 自动起的标题")
    }

    // MARK: - ClaudeDetailScanner 已是「通用」扫描器

    /// ⛔ 最严重的那个：`aggregate` 里曾硬判 `providerId == "claude-code"`，其余一律返回空。
    /// 文件源参数化了、聚合没跟上 → Cowork / Qoder CLI / Qoder Work 详情页全空。
    /// 这里用源码断言兜底（无法轻易构造 actor 的私有 Unit）：确保那道硬门没被改回来。
    func testClaudeDetailScannerHasNoProviderHardGate() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // usageBarCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/usageBarProviders/ClaudeDetailScanner.swift")
        let src = try String(contentsOf: path, encoding: .utf8)

        // 允许注释里提到（我们特意留了说明），但不允许真的存在这句 guard 代码
        let codeLines = src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            .joined(separator: "\n")

        XCTAssertFalse(codeLines.contains(#"guard providerId == "claude-code""#),
                       """
                       ⛔ 回归：`ClaudeDetailScanner.aggregate` 又硬判 providerId 了。
                       它现在是「Claude 同构 transcript」的通用扫描器 ——
                       Cowork / Qoder CLI / Qoder Work 都复用它，硬判会让这三个详情页全空。
                       """)
    }
}
