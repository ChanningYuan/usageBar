import Foundation

/// Qoder token 用量开关（env gate）的检测 / 写入 / 撤销。
///
/// 背景：Qoder CLI 与千问办公（QwenWorkCN）都使用 Qoder Agent SDK 的
/// `EMPTY_USAGE` gate，但 CN binary 会把变量前缀展开为 `QODERCN_`：
/// - Qoder CLI：`QODER_EXPOSE_TOKEN_USAGE=1`
/// - 千问办公：`QODERCN_EXPOSE_TOKEN_USAGE=1`
///
/// usageBar 把两行 export 幂等地写进 shell profile（+ launchctl），可一键撤销。CLI 新开终端
/// 生效；两个 GUI app 都须重启才生效。
/// （Qoder IDE 不受此 gate，token 直写 SQLite，无需开关。）
/// 详见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md（CLI 前身见 docs/0625-Qoder全家桶token计量/qoder-cli-usage-gate-fix.md）。
///
/// 受 gate 产品在主列表该挂哪种提示（纯逻辑，抽出来是为了能被测试锁住）。
///
/// 三态很容易顾此失彼——2026-08-04 就在这里翻过两次车：
/// 1. 先是「gate 已开但 app 没重启」完全静默：token=0 让整行被过滤掉，用户什么都看不到；
/// 2. 补提示时判据只写了「gate 已开 + 装过 + token=0」，于是**当天没用过**的产品也被提示重启。
///
/// 所以判据必须同时看四个输入，缺一个就会误报或漏报。
public enum GateHintState: Equatable {
    /// 不需要任何提示
    case none
    /// gate 没开 → 「token 统计未开启 · 去开启」
    case notEnabled
    /// gate 开了、这个周期也确实用过，但 token 仍是 0 → 目标 app 没重启，环境变量没被继承
    case needsRestart

    /// - Parameters:
    ///   - present: 这个产品在本机用过（有会话目录）
    ///   - gateEnabled: 对应的环境变量已写进 profile / launchctl
    ///   - windowToken: 当前周期该 provider 统计到的 token
    ///   - hasLogActivityInWindow: 当前周期内有没有写过会话日志（**不看 token 是否为 0**）
    public static func evaluate(
        present: Bool,
        gateEnabled: Bool,
        windowToken: Int,
        hasLogActivityInWindow: Bool
    ) -> GateHintState {
        // 没装/没用过 → 与用户无关，别拿开关去打扰他
        guard present else { return .none }
        // gate 没开 → 无论有没有用量都要给开启引导（否则用户永远不知道能开）
        guard gateEnabled else { return .notEnabled }
        // gate 开了且有 token → 一切正常
        guard windowToken == 0 else { return .none }
        // gate 开了、token 却是 0：只有「这个周期确实用过」才是没重启；
        // 没有日志活动 = 今天单纯没用它，属于正常，不提示。
        return hasLogActivityInWindow ? .needsRestart : .none
    }
}

/// ⚠️ 只读检测会 spawn `launchctl getenv`（仅当 profile 标记块不存在时），
/// 调用方应在 UI 出现时（onAppear）触发，不要放进高频循环。
public enum QoderUsageEnvGate {
    public static let qoderEnvName = "QODER_EXPOSE_TOKEN_USAGE"
    public static let qwenWorkEnvName = "QODERCN_EXPOSE_TOKEN_USAGE"
    public static let envNames = [qoderEnvName, qwenWorkEnvName]

    private static let beginMarker = "# BEGIN usageBar-qodercli-usage"
    private static let endMarker = "# END usageBar-qodercli-usage"

    /// 写进 profile 的标记块（幂等识别靠 BEGIN/END）。
    ///
    /// v0.3.33 起**按产品按需生成**：块里放哪几行由 `names` 决定，而不是恒定两行。
    /// 这样两个产品的开关才能各开各的——此前一键开启恒写两行、撤销恒删两行，
    /// 用户只用其中一个产品时被迫连另一个的变量一起写进 `~/.zshrc`。
    static func managedBlock(for names: Set<String>) -> String {
        var lines = [beginMarker]
        if names.contains(qoderEnvName) {
            lines.append("# 让 Qoder CLI 把真实 token 用量写进本地日志。")
            lines.append("export \(qoderEnvName)=1")
        }
        if names.contains(qwenWorkEnvName) {
            lines.append("# 千问办公内置 CN binary，变量前缀是 QODERCN_。")
            lines.append("export \(qwenWorkEnvName)=1")
        }
        lines.append("# gate 只对之后的新请求生效；CLI 需新开终端，千问办公需重启 app。")
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// 兼容旧调用（两个都开）——设置页「已写入」展示用。
    static var managedBlock: String { managedBlock(for: Set(envNames)) }

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
        // ⚠️ **两个源都要看**（v0.3.33 修）：判据原先只认旧 transcript 目录 `~/.qoder/projects`，
        // 但 qodercli 1.1.13 起大量调用带 `--no-session-persistence`，**根本不写那个目录**——
        // 只在 `~/.qoder/logs/sessions/**/segments/*.jsonl` 留诊断日志。
        // 结果：这类用户明明天天用 CLI，`present` 却恒为 false → 设置页的 gate 横幅
        // 压根不出现，连「去开启」的入口都看不到（本机实测：projects 目录不存在、
        // segments 有 2 个日志文件，横幅缺失）。
        if hasEntries(".qoder/projects") { return true }
        return hasFiles(under: home.appendingPathComponent(".qoder/logs/sessions"), ext: "jsonl")
    }

    /// 目录存在且非空
    private static func hasEntries(_ relativePath: String) -> Bool {
        let dir = home.appendingPathComponent(relativePath)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !entries.isEmpty
    }

    /// 递归找有没有指定后缀的文件（找到一个就返回，不全量枚举）
    private static func hasFiles(under root: URL, ext: String) -> Bool {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in en where url.pathExtension == ext { return true }
        return false
    }


    /// 千问办公是否「用过」：`~/.qwenworkcn/projects` 下有会话条目即算。
    /// 千问办公内置 CN 版 Qoder Agent SDK，受 `QODERCN_EXPOSE_TOKEN_USAGE` gate 控制。
    public static func isQwenWorkPresent() -> Bool {
        // 同 `isQoderCliPresent`：千问办公的 token 真值也在 segments 日志里，
        // 只认 projects 目录会漏判（两个源任一有内容就算用过）。
        if hasEntries(".qwenworkcn/projects") { return true }
        return hasFiles(under: home.appendingPathComponent(".qwenworkcn/logs/sessions"), ext: "jsonl")
    }

    /// 受 gate 产品**最近一次产生会话日志**的时间（只看有没有写日志，不看 token 是不是 0）。
    ///
    /// 用来区分两种「token = 0」——它们长得一样，但只有后者该提示重启：
    /// - **今天根本没用过这个工具** → 本周期没有日志活动 → 0 是正常的，什么都不该提示；
    /// - **用了，但 gate 没在目标进程里生效** → 本周期有日志活动、token 却全是 0 → 提示「重启后开始记录」。
    ///
    /// ⚠️ 别退回成「gate 已开 + 装过 + token=0」就提示：那会对**今天没用过**的产品误报
    /// （2026-08-04 验收现场：用户当天没开千问办公，却被提示「重启千问办公」）。
    ///
    /// 只取最新 mtime、不解析内容。调用方应在每次刷新时取一次缓存起来（见 `QoderUsageStatus`），
    /// **别放进 SwiftUI body 里按需调用**——那会每次重绘都扫盘。
    public static func latestSessionActivity(for productId: String) -> Date? {
        let root: URL
        switch productId {
        case "qoder-cli":  root = home.appendingPathComponent(".qoder/projects")
        case "qwen-work":  root = home.appendingPathComponent(".qwenworkcn/logs/sessions")
        default: return nil
        }
        return newestLogDate(under: root)
    }

    private static func newestLogDate(under root: URL) -> Date? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var newest: Date?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }

    /// Qoder CLI 的 gate 是否已开启。
    public static func isQoderEnabled() -> Bool {
        isEnvEnabled(qoderEnvName)
    }

    /// 千问办公的 CN gate 是否已开启。
    public static func isQwenWorkEnabled() -> Bool {
        isEnvEnabled(qwenWorkEnvName)
    }

    /// 所有「已经用过」的受控产品都开启才算完成；未安装/未使用的产品不强制要求。
    public static func isEnabled() -> Bool {
        allRequiredProductsEnabled(
            qoderPresent: isQoderCliPresent(),
            qwenWorkPresent: isQwenWorkPresent(),
            enabledEnvNames: Set(envNames.filter(isEnvEnabled))
        )
    }

    static func allRequiredProductsEnabled(
        qoderPresent: Bool,
        qwenWorkPresent: Bool,
        enabledEnvNames: Set<String>
    ) -> Bool {
        guard qoderPresent || qwenWorkPresent else { return false }
        return (!qoderPresent || enabledEnvNames.contains(qoderEnvName))
            && (!qwenWorkPresent || enabledEnvNames.contains(qwenWorkEnvName))
    }

    private static func isEnvEnabled(_ name: String) -> Bool {
        if let text = try? String(contentsOf: profilePath, encoding: .utf8),
           enabledEnvNames(inProfileText: text).contains(name) {
            return true
        }
        return launchctlValue(name) == "1"
    }

    /// 只解析 usageBar 自己管理的标记块，避免把用户注释或其它脚本误判成已开启。
    static func enabledEnvNames(inProfileText text: String) -> Set<String> {
        guard text.contains(beginMarker), text.contains(endMarker) else { return [] }
        var inside = false
        var enabled = Set<String>()
        for rawLine in text.components(separatedBy: "\n") {
            if rawLine.contains(beginMarker) { inside = true; continue }
            if rawLine.contains(endMarker) { inside = false; continue }
            guard inside else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for name in envNames where line == "export \(name)=1" || line == "\(name)=1" {
                enabled.insert(name)
            }
        }
        return enabled
    }

    private static func launchctlValue(_ envName: String) -> String? {
        let out = runProcess("/bin/launchctl", ["getenv", envName])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    // MARK: - 写入 / 撤销

    /// 幂等开启**指定的变量**：profile 重写标记块 + launchctl setenv。
    /// 返回 profile 是否写入成功（launchctl 是 best-effort）。
    ///
    /// ⚠️ 标记块只有一个（BEGIN/END 一对），所以每次都要把**当前应启用的全集**一起写进去：
    /// 已开的 + 本次要开的。只写本次这一个会把另一个产品的行冲掉。
    @discardableResult
    public static func enable(_ envName: String) -> Bool {
        var target = currentlyEnabledInProfile()
        target.insert(envName)
        let ok = writeProfile(names: target)
        runProcess("/bin/launchctl", ["setenv", envName, "1"])
        return ok
    }

    /// 撤销**指定的变量**：从标记块里去掉它（另一个若已开则保留），launchctl unsetenv。
    @discardableResult
    public static func disable(_ envName: String) -> Bool {
        var target = currentlyEnabledInProfile()
        target.remove(envName)
        let ok = writeProfile(names: target)
        runProcess("/bin/launchctl", ["unsetenv", envName])
        return ok
    }

    /// 两个都开（兼容旧调用 / 引导 sheet 的「全部开启」）
    @discardableResult
    public static func enable() -> Bool {
        let ok = writeProfile(names: Set(envNames))
        for envName in envNames { runProcess("/bin/launchctl", ["setenv", envName, "1"]) }
        return ok
    }

    /// 全部撤销
    @discardableResult
    public static func disable() -> Bool {
        let ok = writeProfile(names: [])
        for envName in envNames { runProcess("/bin/launchctl", ["unsetenv", envName]) }
        return ok
    }

    /// 当前 profile 标记块里已经写着哪几个变量
    private static func currentlyEnabledInProfile() -> Set<String> {
        guard let text = try? String(contentsOf: profilePath, encoding: .utf8) else { return [] }
        return enabledEnvNames(inProfileText: text)
    }

    /// launchctl 自愈（issue #3）：profile 标记块里开关还在、但 launchctl（GUI app 的环境变量表，
    /// **重启电脑即清空**，而 `enable()` 只在开启那一刻写过一次）里的值丢了 → 自动补写。
    ///
    /// 为什么值得补：GUI app（如千问办公）启动时用 `zsh -ilc` 抓 shell 环境有 30 秒超时，超时会回退到
    /// launchd 基础环境——此时 launchctl 里有值就能接住 gate，token 不再静默归零
    /// （2026-07-14 A/B 实证的故障链，见 issue #3）。
    ///
    /// 幂等、毫秒级；只补 profile 已启用的变量，没开开关的用户零开销。
    /// ⚠️ 会 spawn `launchctl` 进程：调用方放后台任务里跑（app 启动 + 每轮刷新顺带），别进 UI 循环。
    public static func selfHealLaunchctl() {
        guard let text = try? String(contentsOf: profilePath, encoding: .utf8) else { return }
        for name in enabledEnvNames(inProfileText: text) where launchctlValue(name) != "1" {
            runProcess("/bin/launchctl", ["setenv", name, "1"])
        }
    }

    /// 重写 profile：增量、非破坏性。
    /// 读整份原文 → 只剥掉我们自己的 BEGIN/END 标记块 → adding=true 再追加新块 → 写回。
    /// 用户其它内容（PATH / alias / 别的 export）原样保留。
    private static func writeProfile(names: Set<String>) -> Bool {
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
        if !names.isEmpty {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            if !text.isEmpty { text += "\n" }
            text += managedBlock(for: names) + "\n"
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
