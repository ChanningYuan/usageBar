import Foundation
import usageBarCore

/// Qoder CLI **自己的**额度来源（v0.3.37 新增）。
///
/// 起因：外部用户 2026-08-28 报「Qoder CLI 明明能正常调用，usageBar 却说『登录凭证已失效』」。
/// 根因是 CLI 行的额度从来就不是 CLI 的——`QoderRateLimitReader` 只读 QoderWork / Qoder IDE 的凭证，
/// 那两处失败（凭证过期 / 解不出 / 401）被原样挂到了 `qoder-cli` 这一行。
/// 本 reader 给 CLI 行补一条**归属正确**的数据源，让它不必再靠别的产品代领。
///
/// 两个能力，都不碰系统钥匙串：
/// 1. `latestLoggedQuota()` —— 读 CLI **自己**的日志 `~/.qoder/logs/runs/<run>/qodercli.log`，
///    捞最近一条 `getQuotaUsage` 的成功响应。响应体与官方 API 完全同构（CLI 就是去打的那个接口），
///    所以直接喂 `QoderRateLimitReader.snapshot(fromQuota:)`，**不需要新写解析**。
///    响应里自带 `userId`，因此这条路顺带免费给出「CLI 登录的是哪个账号」。
/// 2. `identity()` —— 跑 `qodercli status -o json` 判登录态。**只在日志里捞不到额度时才起进程**
///    （2026-08-28 本机实测：冷启 2.7s、热 0.7s），绝大多数刷新一个进程都不起。
///
/// ⚠️ 日志格式没有兼容承诺（`status -o json` 才是官方稳定契约，但它**不含额度**——
/// 2026-08-28 实测 `qodercli --help` 全部子命令里没有 `quota`）。所以日志只当「有则更好」的来源：
/// 解析失败一律回落到中性态，绝不因此报错。官方哪天给了机器可读的额度命令，换掉这一段即可。
public struct QoderCliQuotaReader {
    public init() {}

    public static let providerId = "qoder-cli"

    /// `qodercli status -o json` 的结果
    public struct Identity: Sendable, Equatable {
        public let loggedIn: Bool
        /// 账号 UUID（从 `avatar_url` 的 `/users/<uuid>/` 段取）
        public let userId: String?
        public let userType: String?
    }

    /// 日志里捞到的一条额度
    public struct LoggedQuota: Sendable {
        /// 已经转好的快照，`capturedAt` = 日志里那条响应的**真实时间**（不是 now）
        public let snapshot: RateLimitSnapshot
        /// 响应体自带的账号 id
        public let userId: String?
    }

    // MARK: - 1. CLI 自己日志里的额度

    private static let quotaMarker = "quota/usage response:"

    /// 扫 `~/.qoder/logs/runs/*/qodercli.log`，返回**最近**一条成功的额度响应。
    ///
    /// 目录名是 ISO 时间戳前缀（`2026-08-28T10-08-32-958+08-00-2qpkcn-p13096`），
    /// 字典序倒排即时间倒排 → 从新到旧扫，命中即停。
    /// 2026-08-28 本机实测：全部 20 个 run 合计 388 KB、最大单文件 60 KB，全扫也很便宜，不设限量。
    public func latestLoggedQuota(providerId: String = providerId) -> LoggedQuota? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".qoder/logs/runs")
        guard let runs = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        for run in runs.sorted(by: >) {
            let log = root.appendingPathComponent(run).appendingPathComponent("qodercli.log")
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
            if let hit = Self.parseLatestQuota(in: text, providerId: providerId) { return hit }
        }
        return nil
    }

    /// 从一份日志正文里取**最后**一条额度响应（一个 run 里可能打多次，要最新那条）。
    /// 静态纯函数，单测直接喂真实日志片段。
    static func parseLatestQuota(in text: String, providerId: String = providerId) -> LoggedQuota? {
        var searchEnd = text.endIndex
        while let marker = text.range(of: quotaMarker, options: .backwards,
                                      range: text.startIndex..<searchEnd) {
            searchEnd = marker.lowerBound
            guard let body = Self.balancedJSON(in: text, from: marker.upperBound),
                  let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            else { continue }
            // 行首时间戳 = 这条额度的真实采集时刻；解不出就不用这条（宁可没有，也不谎报采集时间）
            guard let at = Self.lineTimestamp(in: text, before: marker.lowerBound) else { continue }
            let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: at, providerId: providerId)
            // 最新响应的所有额度池都无可展示数字时也照样返回，别继续往下翻出旧余额。
            return LoggedQuota(snapshot: snap, userId: obj["userId"] as? String)
        }
        return nil
    }

    /// 从 `from` 起找第一个 `{`，按括号配平截出完整 JSON（跳过字符串字面量里的括号与转义）。
    static func balancedJSON(in text: String, from: String.Index) -> String? {
        guard let start = text[from...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...i]) }
                }
            }
            // 日志一行一条，越过换行还没配平说明这条被截断了
            if ch == "\n" && depth > 0 && !inString { return nil }
            i = text.index(after: i)
        }
        return nil
    }

    /// `ISO8601DateFormatter` 非 Sendable，但 macOS 10.12+ 起它自身线程安全——
    /// 与 `JSONLReader` 同款处理（本项目既有约定）。
    nonisolated(unsafe) private static let logStampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 取 `idx` 所在行开头的时间戳：`2026-08-28T10:08:38.871+08:00 INFO  debug.message …`
    static func lineTimestamp(in text: String, before idx: String.Index) -> Date? {
        var lineStart = idx
        while lineStart > text.startIndex {
            let prev = text.index(before: lineStart)
            if text[prev] == "\n" { break }
            lineStart = prev
        }
        guard let sep = text[lineStart...].firstIndex(of: " ") else { return nil }
        return logStampFormatter.date(from: String(text[lineStart..<sep]))
    }

    // MARK: - 2. qodercli status -o json（官方稳定契约，判登录态）

    /// identity 结果缓存——起进程要 0.7s，别每轮刷新都跑。
    nonisolated(unsafe) private static var cachedIdentity: (value: Identity, at: Date)?
    private static let identityTTL: TimeInterval = 5 * 60

    public static func clearCache() { cachedIdentity = nil }

    /// 跑 `qodercli status -o json`。CLI 没装 / 跑不起来 / 输出认不出 → nil（**不等于「未登录」**，
    /// 调用方要把这三种情况和「明确未登录」分开，否则又会造出一个「压平了的错误态」）。
    public func identity(now: Date = Date()) -> Identity? {
        if let c = Self.cachedIdentity, now.timeIntervalSince(c.at) < Self.identityTTL { return c.value }
        guard let bin = Self.binary() else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["status", "-o", "json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        // 超时熔断：实测热态 0.7s / 冷态 2.7s，给 15s 富余
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { proc.waitUntilExit(); group.leave() }
        if group.wait(timeout: .now() + 15) == .timedOut {
            proc.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0, let id = Self.parseStatus(data) else { return nil }
        Self.cachedIdentity = (id, now)
        return id
    }

    /// `{"logged_in":true,"version":"1.1.21","username":"…","email":"…",
    ///   "avatar_url":"https://qoder.com/users/<uuid>/default/avatars","user_type":"personal_standard"}`
    /// —— 2026-08-28 本机 qodercli 1.1.21 实测原文。
    static func parseStatus(_ data: Data) -> Identity? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = obj["logged_in"] as? Bool else { return nil }
        return Identity(loggedIn: loggedIn,
                        userId: (obj["avatar_url"] as? String).flatMap(Self.userId(fromAvatarURL:)),
                        userType: obj["user_type"] as? String)
    }

    /// `https://qoder.com/users/019efc88-48a7-708b-b5ca-80643e713b67/default/avatars` → UUID
    static func userId(fromAvatarURL url: String) -> String? {
        let parts = url.split(separator: "/")
        guard let i = parts.firstIndex(of: "users"), i + 1 < parts.count else { return nil }
        let candidate = String(parts[i + 1])
        return isUUID(candidate) ? candidate : nil
    }

    /// 发现链。`~/.qoder/bin/qodercli/qodercli-<版本>` 是官方安装器的落点（外部报告人那台就是这种），
    /// 同目录多版本时取名字最大的（版本号字典序足够用）。
    static func binary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let fixed = ["\(home.path)/.npm-global/bin/qodercli",
                     "\(home.path)/.local/bin/qodercli",
                     "/opt/homebrew/bin/qodercli",
                     "/usr/local/bin/qodercli"]
        if let hit = fixed.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        let nested = home.appendingPathComponent(".qoder/bin/qodercli")
        if let entries = try? fm.contentsOfDirectory(atPath: nested.path) {
            for name in entries.sorted(by: >) {
                let p = nested.appendingPathComponent(name).path
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    // MARK: - 账号归属

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// 「这份 Work / IDE 凭证和 CLI 是同一个账号吗」。
    ///
    /// ⚠️ 只有**确凿证明是两个账号**才返回 false；判不出一律 true。
    /// 方向是刻意的：判不出就沿用老行为（继续代领），不会让现在能看到数字的人突然看不到；
    /// 而误判成同账号的代价只是「多显示一个同池数字」，误判成不同账号却会让人白丢额度显示。
    /// 凭证侧的指纹可能是 JWT sub / uid / email / token 原文（见 `accountFingerprint`），
    /// 只有两边都是 UUID 形态时才具备可比性。
    static func sameAccount(credential fingerprint: String, cliUserId: String) -> Bool {
        if fingerprint == cliUserId { return true }
        if isUUID(fingerprint) && isUUID(cliUserId) { return false }
        return true
    }
}
