import Foundation
import usageBarCore

/// Claude 额度读取 · CLI 抄 `/usage`（v0.3.24，statusline 的兜底路线）。
///
/// 实测（2026-07-15）：`claude -p "/usage"` 直接抄到结构化文本，**不消耗 token**（该会话无 assistant/usage）。
/// 副作用：每次抄屏在 cwd 对应的 projects 目录留一个空会话文件 → 用**固定探测 cwd** 集中，抄完**清理**。
/// 起进程慢（加超时熔断），适合没配 statusline 时兜底。
public struct ClaudeCLIReader {
    public init() {}

    public static let providerId = "claude-code"
    /// 固定探测目录：所有 /usage 抄屏会话集中在此对应的 projects 子目录，便于清理。
    private static let probeCwd = "/tmp/usagebar-claude-probe"

    public func read(now: Date = Date()) -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }
        guard let bin = Self.claudeBinary() else { return fail(.noDataSource) }
        try? FileManager.default.createDirectory(atPath: Self.probeCwd, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["-p", "/usage"]
        proc.currentDirectoryURL = URL(fileURLWithPath: Self.probeCwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        defer { Self.cleanupProbeSessions() }   // 无论成败都清理抄屏留下的空会话

        do {
            try proc.run()
        } catch { return fail(.noDataSource) }

        // 超时熔断：15 秒没退出就杀（/usage idle 卡 loading 是已知 bug）
        let deadline = DispatchTime.now() + 15
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { proc.waitUntilExit(); group.leave() }
        if group.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            return fail(.network)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return fail(.network)
        }
        let windows = Self.parseUsageText(text)
        if windows.isEmpty { return fail(.noQuotaData) }
        return RateLimitSnapshot(providerId: Self.providerId, windows: windows,
                                 planType: ClaudeStatuslineReader.planLabel(),   // 零钥匙串，来源同 statusline
                                 capturedAt: now, error: nil)
    }

    /// 解析 `/usage` 文本输出：
    /// `Current session: 3% used · resets …` → 5h
    /// `Current week (all models): 48% used · …` → 7d
    /// `Current week (Fable): 69% used · …` → 分模型
    static func parseUsageText(_ text: String) -> [RateLimitWindow] {
        var out: [RateLimitWindow] = []
        func pct(_ pattern: String) -> Double? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) else { return nil }
            return Double(text[r])
        }
        if let p = pct(#"Current session:\s*(\d+)%"#) {
            out.append(RateLimitWindow(kind: "session", label: "5h", usedPercent: p))
        }
        if let p = pct(#"Current week \(all models\):\s*(\d+)%"#) {
            out.append(RateLimitWindow(kind: "weekly_all", label: "7d", usedPercent: p))
        }
        // 分模型周限额：Current week (Fable): 69%（跳过 all models）
        if let re = try? NSRegularExpression(pattern: #"Current week \(([^)]+)\):\s*(\d+)%"#) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let mr = Range(m.range(at: 1), in: text), let pr = Range(m.range(at: 2), in: text) else { continue }
                let model = String(text[mr])
                if model == "all models" { continue }
                if let p = Double(text[pr]) {
                    out.append(RateLimitWindow(kind: "weekly_scoped", label: model,
                                               usedPercent: p, scopeModel: model))
                }
            }
        }
        return out
    }

    static func claudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 删掉探测 cwd 对应的 projects 会话目录（cwd 的 / 被 claude 编码成 -）
    static func cleanupProbeSessions() {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return }
        for name in entries where name.contains("usagebar-claude-probe") {
            try? FileManager.default.removeItem(at: projects.appendingPathComponent(name))
        }
    }
}
