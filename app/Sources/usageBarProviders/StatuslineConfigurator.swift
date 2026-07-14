import Foundation

/// 把「导出额度」一行注入 Claude 的 statusline 脚本（v0.3.24 · statusline 数据源的配置动作）。
///
/// Claude Code 每渲染一次状态栏，就会把含 `rate_limits` 的 JSON 从 stdin 喂给 statusline 脚本。
/// 我们在脚本里加一行：`echo "$input" | jq -c '.rate_limits' > ~/.claude/usagebar-quota.json`，
/// 于是 Claude 顺手把额度写到文件，usageBar 只读文件——零钥匙串、零起进程。
///
/// 注入**幂等**（sentinel 包裹，重复调用不重复加），且**只追加、不改用户原有逻辑**（插在读完 stdin 那行之后）。
public enum StatuslineConfigurator {
    private static let beginMark = "# >>> usageBar quota export (auto-injected, safe to remove) >>>"
    private static let endMark = "# <<< usageBar quota export <<<"

    private static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    private static var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    private static var defaultScript: URL { claudeDir.appendingPathComponent("statusline.sh") }

    public enum Result { case injected, alreadyPresent, createdNew, failed(String) }

    /// 配置 statusline 导出额度。返回结果供引导 sheet 反馈。
    @discardableResult
    public static func configure() -> Result {
        let injectBlock = """
        \(beginMark)
        echo "$input" | jq -c '.rate_limits // empty' > "$HOME/.claude/usagebar-quota.json" 2>/dev/null
        \(endMark)
        """

        // 1. 定位 statusline 脚本：读 settings.json 的 statusLine.command
        if let script = resolveExistingScript() {
            guard var text = try? String(contentsOf: script, encoding: .utf8) else {
                return .failed("读不到 \(script.lastPathComponent)")
            }
            if text.contains(beginMark) { return .alreadyPresent }
            // 插在第一处读 stdin（input=$(cat)）之后；找不到就插在 shebang 后
            let injected = insert(injectBlock, into: text)
            text = injected
            do {
                try text.write(to: script, atomically: true, encoding: .utf8)
                return .injected
            } catch { return .failed(error.localizedDescription) }
        }

        // 2. 没有 statusLine 配置 → 新建一个最小脚本并注册
        return createAndRegister(injectBlock: injectBlock)
    }

    /// 撤销注入（切到别的数据源 / 关闭 Claude 额度时用）——只删我们那段，不动用户逻辑。
    @discardableResult
    public static func deconfigure() -> Bool {
        guard let script = resolveExistingScript(),
              var text = try? String(contentsOf: script, encoding: .utf8),
              text.contains(beginMark) else { return false }
        text = stripBlock(from: text)
        return (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil
    }

    /// statusline 是否已配置好导出（引导 sheet 判断该显示「已配置」还是「去配置」）
    public static var isConfigured: Bool {
        guard let script = resolveExistingScript(),
              let text = try? String(contentsOf: script, encoding: .utf8) else { return false }
        return text.contains(beginMark)
    }

    // MARK: - 内部

    /// 从 settings.json 的 statusLine.command 解析出脚本路径（展开 ~，剥掉 `bash `/`sh ` 前缀）
    private static func resolveExistingScript() -> URL? {
        guard let data = try? Data(contentsOf: settingsFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sl = obj["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else {
            // 没配 statusLine：若默认脚本已存在也认它
            return FileManager.default.fileExists(atPath: defaultScript.path) ? defaultScript : nil
        }
        // command 形如 "bash ~/.claude/statusline.sh" / "~/.claude/statusline.sh"
        var path = cmd.trimmingCharacters(in: .whitespaces)
        for prefix in ["bash ", "sh ", "zsh ", "/bin/bash ", "/bin/sh "] {
            if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)); break }
        }
        path = path.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("~") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        // 去掉可能的引号
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// 插在第一处 `input=$(cat)` 之后；找不到则插在 shebang 行后；再不行插在开头。
    private static func insert(_ block: String, into text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0.replacingOccurrences(of: " ", with: "").contains("input=$(cat)") || $0.replacingOccurrences(of: " ", with: "").contains("input=\"$(cat)\"") }) {
            lines.insert(block, at: idx + 1)
            return lines.joined(separator: "\n")
        }
        if let sheIdx = lines.firstIndex(where: { $0.hasPrefix("#!") }) {
            lines.insert("input=$(cat)\n" + block, at: sheIdx + 1)
            return lines.joined(separator: "\n")
        }
        return block + "\n" + text
    }

    private static func stripBlock(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let b = lines.firstIndex(of: beginMark), let e = lines.firstIndex(of: endMark), e >= b else { return text }
        lines.removeSubrange(b...e)
        return lines.joined(separator: "\n")
    }

    /// 没有任何 statusLine 时：建最小脚本（透传原状态栏行为 + 导出额度）并写进 settings.json。
    private static func createAndRegister(injectBlock: String) -> Result {
        let script = """
        #!/usr/bin/env bash
        # ~/.claude/statusline.sh —— usageBar 自动创建（用于导出额度到本地文件）
        input=$(cat)
        \(injectBlock)
        # 原样输出模型名，保持状态栏不空
        echo "$input" | jq -r '.model.display_name // ""' 2>/dev/null
        """
        do {
            try script.write(to: defaultScript, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: defaultScript.path)
        } catch { return .failed(error.localizedDescription) }

        // 注册到 settings.json（不覆盖其它键）
        var obj = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: settingsFile)) ?? Data())) as? [String: Any] ?? [:]
        obj["statusLine"] = ["type": "command", "command": "bash ~/.claude/statusline.sh"]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile)
        }
        return .createdNew
    }
}
