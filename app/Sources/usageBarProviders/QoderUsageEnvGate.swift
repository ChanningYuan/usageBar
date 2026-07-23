import Foundation

/// Qoder token 用量开关（env gate）的检测 / 写入 / 撤销。
///
/// 背景：Qoder CLI、QoderWork 与千问办公（QwenWorkCN）共用 Qoder Agent SDK 的
/// `EMPTY_USAGE` gate —— 默认不往本地日志写 token 真值，须设环境变量
/// `QODER_EXPOSE_TOKEN_USAGE=1`。usageBar 帮用户把这行 export 幂等地写进 shell profile
///（+ launchctl），可一键撤销。CLI 新开终端生效；两个 GUI app 都须重启才生效。
/// （Qoder IDE 不受此 gate，token 直写 SQLite，无需开关。）
/// 详见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md（CLI 前身见 docs/0625-Qoder全家桶token计量/qoder-cli-usage-gate-fix.md）。
///
/// ⚠️ 只读检测会 spawn `launchctl getenv`（仅当 profile 标记块不存在时），
/// 调用方应在 UI 出现时（onAppear）触发，不要放进高频循环。
public enum QoderUsageEnvGate {
    public static let envName = "QODER_EXPOSE_TOKEN_USAGE"

    private static let beginMarker = "# BEGIN usageBar-qodercli-usage"
    private static let endMarker = "# END usageBar-qodercli-usage"

    /// 写进 profile 的完整标记块（幂等识别靠 BEGIN/END）
    private static var block: String {
        """
        \(beginMarker)
        # 让 qodercli / QoderWork / 千问办公把真实 token 用量写进本地日志,供 usageBar 统计。
        # 默认不记录(EMPTY_USAGE gate),设此变量=1 才吐真值;只对之后的新请求生效(两个 GUI app 需重启)。
        export \(envName)=1
        \(endMarker)
        """
    }

    // MARK: - 路径

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 目标 shell profile：默认 `~/.zshrc`；`$SHELL` 含 bash 时用 `~/.bash_profile`。
    static var profilePath: URL {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if shell.contains("bash") {
            return home.appendingPathComponent(".bash_profile")
        }
        return home.appendingPathComponent(".zshrc")
    }

    /// 展示给用户看的 profile 名（如 `~/.zshrc`）
    public static var profileDisplayName: String {
        "~/" + profilePath.lastPathComponent
    }

    // MARK: - 检测

    /// qodercli 是否「用过」：`~/.qoder/projects` 下有会话条目即算。
    /// 用作 first-run keep-set 判定 + 横幅是否出现的开关。
    public static func isQoderCliPresent() -> Bool {
        let projects = home.appendingPathComponent(".qoder/projects")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else {
            return false
        }
        return !entries.isEmpty
    }

    /// QoderWork 是否「用过」：`~/.qoderwork/projects` 下有会话条目即算。
    /// 与 CLI 共用同一个 env gate（同一个 `QODER_EXPOSE_TOKEN_USAGE`），故同样用作
    /// first-run keep-set 判定 + 横幅是否出现的开关。
    public static func isQoderWorkPresent() -> Bool {
        let projects = home.appendingPathComponent(".qoderwork/projects")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else {
            return false
        }
        return !entries.isEmpty
    }

    /// 千问办公是否「用过」：`~/.qwenworkcn/projects` 下有会话条目即算。
    /// 千问办公内置同源 Qoder Agent SDK，也受 `QODER_EXPOSE_TOKEN_USAGE` gate 控制。
    public static func isQwenWorkPresent() -> Bool {
        let projects = home.appendingPathComponent(".qwenworkcn/projects")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else {
            return false
        }
        return !entries.isEmpty
    }

    /// token 统计是否已开启：profile 标记块存在，或 launchctl 已 setenv=1。
    public static func isEnabled() -> Bool {
        if profileHasBlock() { return true }
        if launchctlValue() == "1" { return true }
        return false
    }

    private static func profileHasBlock() -> Bool {
        guard let text = try? String(contentsOf: profilePath, encoding: .utf8) else { return false }
        return text.contains(beginMarker) && text.contains("\(envName)=1")
    }

    private static func launchctlValue() -> String? {
        let out = runProcess("/bin/launchctl", ["getenv", envName])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    // MARK: - 写入 / 撤销

    /// 幂等开启：profile 写标记块（已存在则先清再写）+ launchctl setenv。
    /// 返回 profile 是否写入成功（launchctl 是 best-effort）。
    @discardableResult
    public static func enable() -> Bool {
        let ok = writeProfile(adding: true)
        // launchctl 让 GUI / 新登录会话也覆盖；失败不影响 profile 主路径
        runProcess("/bin/launchctl", ["setenv", envName, "1"])
        return ok
    }

    /// 撤销：删 profile 标记块 + launchctl unsetenv。
    @discardableResult
    public static func disable() -> Bool {
        let ok = writeProfile(adding: false)
        runProcess("/bin/launchctl", ["unsetenv", envName])
        return ok
    }

    /// 重写 profile：增量、非破坏性。
    /// 读整份原文 → 只剥掉我们自己的 BEGIN/END 标记块 → adding=true 再追加新块 → 写回。
    /// 用户其它内容（PATH / alias / 别的 export）原样保留。
    private static func writeProfile(adding: Bool) -> Bool {
        let path = profilePath
        // 文件存在但读不出（非 UTF-8 等）→ 宁可开启失败，绝不用"只剩我们的块"覆盖掉用户文件
        var text: String
        if FileManager.default.fileExists(atPath: path.path) {
            guard let existing = try? String(contentsOf: path, encoding: .utf8) else { return false }
            text = existing
        } else {
            text = ""
        }
        text = strippedBlock(from: text)
        if adding {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            if !text.isEmpty { text += "\n" }
            text += block + "\n"
        }
        do {
            try text.write(to: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// 从文本里剥掉 BEGIN..END 标记块（含收拢尾部多余空行）。
    private static func strippedBlock(from text: String) -> String {
        guard text.contains(beginMarker) else { return text }
        var result: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.contains(beginMarker) { inside = true; continue }
            if line.contains(endMarker) { inside = false; continue }
            if !inside { result.append(line) }
        }
        var joined = result.joined(separator: "\n")
        while joined.hasSuffix("\n\n") { joined.removeLast() }
        return joined
    }

    // MARK: - Process helper

    @discardableResult
    private static func runProcess(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
