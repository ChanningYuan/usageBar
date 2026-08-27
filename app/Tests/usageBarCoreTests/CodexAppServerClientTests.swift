import XCTest
@testable import usageBarCore
@testable import usageBarProviders

/// Codex app-server 客户端：启动参数被 CLI 拒绝时必须单独归类。
/// 背景：2026-08-24 Codex 0.149.0-alpha.4 删掉 `-a untrusted`，进程退出码 2；旧版 usageBar 把它当
/// 「连接不上」、顶着 3 天前的旧数字一直显示「更新于 3d 前 · 连接不上 Codex」，无人察觉。
final class CodexAppServerClientTests: XCTestCase {

    func testUsageErrorDetection() {
        let clap = """
        error: invalid value 'untrusted' for '--ask-for-approval <APPROVAL_POLICY>'
          [possible values: on-request, never]

        For more information, try '--help'.
        """
        XCTAssertTrue(CodexAppServerClient.isUsageError(status: 2, stderr: clap))
        XCTAssertTrue(CodexAppServerClient.isUsageError(status: 2, stderr: "error: unexpected argument '--foo' found"))
        XCTAssertFalse(CodexAppServerClient.isUsageError(status: 0, stderr: clap), "退出码 0 不算失败")
        XCTAssertFalse(CodexAppServerClient.isUsageError(status: 1, stderr: "thread 'main' panicked at src/main.rs"),
                       "崩溃不是用法错误")
        XCTAssertFalse(CodexAppServerClient.isUsageError(status: 2, stderr: ""), "没有 stderr 证据不乱判")
    }

    /// 端到端：假 codex 复现「参数被拒、退出码 2」→ 必须是 .incompatibleCLI，不能是 .processFailed
    func testRejectedArgsMapToIncompatibleCLI() throws {
        let fake = try makeFakeCodex("""
        #!/bin/sh
        echo "error: invalid value 'on-request' for '--ask-for-approval <APPROVAL_POLICY>'" >&2
        echo "For more information, try '--help'." >&2
        exit 2
        """)
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        guard case .failure(let e) = CodexAppServerClient.fetch(binary: fake.path, timeout: 5) else {
            return XCTFail("假 codex 不该成功")
        }
        XCTAssertEqual(e, .incompatibleCLI)
    }

    /// 对照：进程无缘无故退了（退出码 1、stderr 不是用法错误）仍是 .processFailed → UI 走「连接不上」
    func testPlainCrashStaysProcessFailed() throws {
        let fake = try makeFakeCodex("""
        #!/bin/sh
        echo "thread 'main' panicked at src/main.rs" >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        guard case .failure(let e) = CodexAppServerClient.fetch(binary: fake.path, timeout: 5) else {
            return XCTFail("假 codex 不该成功")
        }
        XCTAssertEqual(e, .processFailed)
    }

    /// store 语义：.cliIncompatible 不会自愈，不该像 .network 那样保留旧窗口冒充「陈旧但有效」
    @MainActor func testCLIIncompatibleDoesNotRetainStaleWindows() {
        let store = RateLimitStore.shared
        let pid = "codex-test-incompat"
        store.put(RateLimitSnapshot(
            providerId: pid,
            windows: [RateLimitWindow(kind: "codex_primary", label: "7d", windowMinutes: 10080, usedPercent: 21)],
            planType: "prolite", capturedAt: Date(timeIntervalSince1970: 1_000_000), error: nil))
        store.put(RateLimitSnapshot(providerId: pid, windows: [], capturedAt: Date(), error: .cliIncompatible))
        let after = store.snapshot(for: pid)
        XCTAssertEqual(after?.windows.count, 0, "不会自愈的错误不该顶着几天前的旧数字")
        XCTAssertEqual(after?.error, .cliIncompatible)
        store.remove(pid)
    }

    private func makeFakeCodex(_ script: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagebar-fake-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("codex")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
