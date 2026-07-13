import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// v0.3.21：Claude Code provider 合并 + 来源层 + 价目快照兜底。
final class ClaudeSourceTests: XCTestCase {

    // MARK: - 来源判定（纯函数打表）

    func testClassifyOfficialVsRelay() {
        // 官方直连：原生 msg_ 前缀 + claude 模型（订阅 OAuth 与官方 API-key 同为此形态，日志侧不可分）
        XCTAssertEqual(ClaudeSource.classify(messageId: "msg_011CcyVmgKnGmDxWEUYmKm85",
                                             modelId: "claude-fable-5"), .official)

        // 云渠道（Vertex / Bedrock）归中转/代理
        XCTAssertEqual(ClaudeSource.classify(messageId: "msg_vrtx_01abc", modelId: "claude-sonnet-5"), .relay)
        XCTAssertEqual(ClaudeSource.classify(messageId: "msg_bdrk_01abc", modelId: "claude-sonnet-5"), .relay)

        // ccx 等中转（OpenAI Responses / ChatCompletions 格式）
        XCTAssertEqual(ClaudeSource.classify(messageId: "resp_059f48be89dff0ad01", modelId: "gpt-5.6-sol"), .relay)
        XCTAssertEqual(ClaudeSource.classify(messageId: "chatcmpl-abc123", modelId: "claude-fable-5"), .relay)

        // 模型域交叉校验：中转伪造官方 msg_ 前缀，但模型不是 claude-* → 仍判中转
        XCTAssertEqual(ClaudeSource.classify(messageId: "msg_01FakeOfficialPrefix",
                                             modelId: "gpt-5.6-sol"), .relay)

        // 未知 / 空前缀兜底进中转 —— 方向与旧分类器相反（旧的兜进订阅，把 ccx 的 gpt 流量错贴成官方）
        XCTAssertEqual(ClaudeSource.classify(messageId: "weird_id", modelId: "claude-opus-4-8"), .relay)
        XCTAssertEqual(ClaudeSource.classify(messageId: "", modelId: "claude-fable-5"), .relay)
    }

    // MARK: - 主聚合：合并守恒

    /// 同一份日志里混着官方 / Vertex / ccx 三种消息，主聚合后应全部归 `claude-code` 一行，
    /// 且总量 == 三者之和（v0.3.20 会拆成 claude-sub + claude-api 两行）。同时锁住 message.id 去重。
    func testClaudeCodeAggregatesAllSourcesIntoOneProvider() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")

        func line(_ id: String, _ model: String, _ input: Int, _ output: Int) -> String {
            "{\"type\":\"assistant\",\"timestamp\":\"2026-07-13T10:00:00.000Z\",\"sessionId\":\"s1\","
                + "\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":"
                + "{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":0}}}"
        }
        let content = [
            line("msg_01official", "claude-fable-5", 100, 10),
            line("msg_vrtx_cloud", "claude-sonnet-5", 200, 20),
            line("resp_relay", "gpt-5.6-sol", 300, 30),
            line("msg_01official", "claude-fable-5", 100, 10),   // 流式重复落盘的同一条 → 只计一次
        ].joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)

        let records = try ClaudeTranscriptParser.parse(url: url) { _ in "claude-code" }
        XCTAssertEqual(records.count, 1, "三种来源应合并进 claude-code 的单条日聚合")
        XCTAssertEqual(records.first?.provider, "claude-code")
        XCTAssertEqual(records.first?.token, 110 + 220 + 330, "合并前后总量守恒，且同 message.id 只计一次")
    }

    /// 锁死 v0.3.21 的 schema bump：改回 6 会让旧缓存里的 claude-sub/claude-api 记录复活，
    /// 而新 provider 按 claude-code 去 filter 一条都找不到 → 主列表全 0。
    func testCacheSchemaBumpedForProviderMerge() {
        XCTAssertGreaterThanOrEqual(PersistedCache.currentSchemaVersion, 7)
    }

    // MARK: - 价目快照（加固④）

    /// 安装包内置快照必须是可解析的完整表。发版时 curl 挂了 / 拉到残表的话，
    /// 别让空快照混进安装包——那等于兜底失效，用户又回到全员 $0。
    func testBundledPricingSnapshotIsValid() throws {
        // #filePath = app/Tests/usageBarCoreTests/ClaudeSourceTests.swift → 上溯三级到 app/
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let snapshot = appDir.appendingPathComponent("Sources/usageBar/pricing-snapshot.json")

        let data = try Data(contentsOf: snapshot)
        let parsed = try XCTUnwrap(RemotePricing.parse(data), "快照解析失败")
        XCTAssertGreaterThanOrEqual(parsed.count, 30, "快照厂商数过少，疑似残表")
        XCTAssertNotNil(parsed["anthropic"]?["claude-fable-5"], "快照里应有 claude 价目")
        XCTAssertNotNil(parsed["openai"]?["gpt-5.6-sol"], "快照里应有 gpt 价目")
    }
}
