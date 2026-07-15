import Foundation
import os

/// 远程价目层：`usagebar.cn/pricing.json`（服务器 cron 每日从 models.dev 全量瘦身生成，
/// 结构 `{"providers": {providerID: {modelID: {input/output/cache_read/cache_write}}}}`，
/// 单价 $/1M token，约 146 厂商 5000 模型）。
///
/// 角色（2026-07-12 起）：`UnifiedPricing` 的**唯一价源**——claude-*/gpt-* 也在这查
/// （内置手工价格表已退役，缘由见 `ModelPricing.swift` 头注 + `_notes/docs/0712-价格统一走远程表/`），
/// 查不到的真长尾按 $0 + 「无价目」引导。
///
/// 更新策略：每日一次 ETag 条件拉取（`refreshIfNeeded`，24h 节流，304 零流量），
/// 缓存在 Application Support；**磁盘无缓存（首启/被手删）时无视节流立即拉**。
///
/// 三层价源（2026-07-13 v0.3.21 加固，驱动案例见 `_notes/docs/0713-ClaudeCode合并与来源层/`）：
///   1. 磁盘缓存（Application Support/usageBar/pricing.json）—— 最新，永远优先
///   2. **安装包内置快照**（build-app.sh 构建时从线上表 curl，随 app 分发）—— 拉取被拦时兜底，
///      新鲜度 = 发版日；只在磁盘缓存不存在时装载，且**不影响强拉判定**（见 `hasDiskCache`）
///   3. 都没有 → $0 + 「无价目」引导
///
/// ⚠️ ETag 与「是否强拉」都以**磁盘缓存是否存在**为准，不看内存里有没有表：
/// 快照装了表但磁盘仍空，此时必须继续无条件强拉，否则快照会把首启拉取顶掉、价格永远停在发版日。
///
/// curl 兜底（v0.3.25）：URLSession 拉取失败（请求异常 / 非 200 / 200 但结构不对）时，
/// 换 `/usr/bin/curl` 子进程再拉一次。实证依据：公司安全软件**按进程**拦截——同一台机器
/// app 进程收到的响应被掉包、终端 curl 同一 URL 正常（2026-07-13/15 同事案例，见
/// `_notes/docs/0713-ClaudeCode合并与来源层/`）。全链路失败原因记入系统日志
/// （subsystem `com.yuanchenyu.usageBar`，Console.app 或 `log stream` 可查），不再静默。
public final class RemotePricing: @unchecked Sendable {
    public static let shared = RemotePricing()

    /// 表龄超过它就在设置页提示「价格表未更新」（拉取失败会静默退化成过期表，必须可见化）
    public static let staleAfter: TimeInterval = 7 * 24 * 3600

    /// 价目表新鲜度（设置页提示用）
    public struct Freshness: Sendable {
        /// 磁盘缓存最后一次成功落盘的时间；nil = 从未成功拉到过
        public let lastUpdated: Date?
        /// 正在用安装包内置快照（= app 从未成功拉到线上表，多半被网络/安全软件拦了）
        public let usingSnapshot: Bool
        /// 表龄 > 7 天，或压根没成功拉到过 → 设置页出提示
        public let isStale: Bool
    }

    /// 单价（$/1M token）。cache_write 按 Anthropic 标准即 5m 档口径。
    public struct Rate: Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite: Double
    }

    private let lock = NSLock()
    private var byProvider: [String: [String: Rate]] = [:]
    /// 扁平表（modelID → Rate）：同名模型多渠道时按 `canonicalProviders` 优先序取值
    private var flat: [String: Rate] = [:]
    private var diskLoaded = false
    /// 当前内存里的表来自安装包内置快照（而非磁盘缓存）
    private var usingSnapshot = false

    /// 同名模型出现在多个渠道（如 openrouter 转售）时，优先采用官方渠道的价格
    private static let canonicalProviders = [
        "anthropic", "openai", "google", "zai", "deepseek",
        "alibaba", "moonshotai", "xai", "mistral",
    ]

    private static let feedURL = URL(string: "https://usagebar.cn/pricing.json")!
    private static let checkIntervalKey = "usagebar.pricingLastCheck.v1"
    private static let etagKey = "usagebar.pricingETag.v1"
    private static let checkInterval: TimeInterval = 24 * 3600
    /// 失败原因必须可查（同事案例排查全靠猜）。插值一律 .public：内容只有状态码/字节数/错误描述，无隐私。
    private static let log = Logger(subsystem: "com.yuanchenyu.usageBar", category: "pricing")

    private var cacheDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("usageBar", isDirectory: true)
    }
    private var cacheFile: URL { cacheDir.appendingPathComponent("pricing.json") }

    // MARK: - 查价

    /// (providerID, modelID) 精确查价；provider 为 nil 或未命中时退化到扁平表。查不到返回 nil。
    public func rate(provider: String?, model: String) -> Rate? {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskLocked()
        if let p = provider, let r = byProvider[p]?[model] { return r }
        return flat[model]
    }

    // MARK: - 拉取

    /// 每日一次条件拉取（内部 24h 节流，随主刷新循环调用即可，非到期直接返回）。
    /// 例外：**磁盘上没有缓存**（首启 / 被手删 / 历次拉取全被拦）时无视节流立即拉——
    /// 远程表是唯一的「活」价源，没落盘就一直强拉，直到成功。
    ///
    /// ⚠️ 判定看**磁盘**不看内存：内置快照会把内存表填满，若还用「内存有没有表」判定，
    /// 装了快照的机器就再也不强拉了，价格永远停在发版日。
    public func refreshIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: Self.checkIntervalKey)
        let throttled = Date().timeIntervalSince1970 - last < Self.checkInterval
        let hasCache = hasDiskCache
        guard !throttled || !hasCache else { return }

        var req = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        // 加固①：只有磁盘缓存在时才带 ETag。缓存没了（或从未落盘）却残留 ETag 的话，
        // 服务器回 304 空响应 → 本地永远装不上表 → 全员 $0 死锁。
        if hasCache, let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data, http: HTTPURLResponse
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard let h = resp as? HTTPURLResponse else {
                Self.log.error("拉取失败：非 HTTP 响应")
                await curlFallback()
                return
            }
            (data, http) = (d, h)
        } catch {
            Self.log.error("拉取失败：\(error.localizedDescription, privacy: .public)")
            await curlFallback()
            return
        }

        // 无论 200/304 都记本次检查时间（304 = 已是最新）
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkIntervalKey)
        if http.statusCode == 304 { return }
        guard http.statusCode == 200 else {
            Self.log.error("拉取失败：HTTP \(http.statusCode, privacy: .public)")
            await curlFallback()
            return
        }

        // 结构校验通过才落盘替换（防服务端残表把本地好缓存冲掉）
        guard let parsed = Self.parse(data), parsed.count >= 30 else {
            // 200 但内容不是价目表——安全软件把响应掉包成拦截页时就长这样，把开头记下来当证据
            let head = String(decoding: data.prefix(64), as: UTF8.self)
            Self.log.error("拉取失败：200 但结构校验不过（\(data.count, privacy: .public) 字节，开头: \(head, privacy: .public)）")
            await curlFallback()
            return
        }
        persist(data, parsed: parsed, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    /// 校验通过的表统一从这里落盘 + 装载（URLSession 主路 / curl 兜底共用）。
    /// 加固②：写盘成功才存 ETag。写失败却存了 ETag → 下轮带 ETag 换回 304 空响应、
    /// 磁盘依然没表 → 死锁。内存表照装，本次会话仍有正确价。
    private func persist(_ data: Data, parsed: [String: [String: Rate]], etag: String?) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let wrote = (try? data.write(to: cacheFile, options: .atomic)) != nil
        if wrote, let etag {
            UserDefaults.standard.set(etag, forKey: Self.etagKey)
        }
        install(parsed)
    }

    /// URLSession 失败后的兜底：换 `/usr/bin/curl` 子进程拉同一 URL。
    /// 针对「安全软件按进程拦截 GUI app、终端 curl 却正常」的公司环境（实证见类头注释）。
    /// 成功后正常落盘，但不存 ETag（没去解析响应头）——下轮仍先走 URLSession，环境恢复后自动回主路；
    /// curl 拿到的表一直是 200 全量，无 304 死锁风险。
    private func curlFallback() async {
        let data: Data? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                proc.arguments = ["-fsS", "--max-time", "30", Self.feedURL.absoluteString]
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = Pipe()
                do { try proc.run() } catch {
                    Self.log.error("curl 兜底启动失败：\(error.localizedDescription, privacy: .public)")
                    cont.resume(returning: nil)
                    return
                }
                let d = out.fileHandleForReading.readDataToEndOfFile()  // --max-time 兜住阻塞上限
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    Self.log.error("curl 兜底失败：退出码 \(proc.terminationStatus, privacy: .public)")
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: d)
            }
        }
        guard let d = data else { return }
        guard let parsed = Self.parse(d), parsed.count >= 30 else {
            Self.log.error("curl 兜底拿到 \(d.count, privacy: .public) 字节但结构校验不过")
            return
        }
        // 兜底成功也算一次有效检查，记时间戳（否则有缓存的机器同一天内不会再试，白省这步）
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkIntervalKey)
        persist(d, parsed: parsed, etag: nil)
        Self.log.notice("URLSession 被拦但 curl 兜底成功——疑似进程级网络拦截，可作为向 IT 申请放行的证据")
    }

    /// 磁盘缓存是否存在。**内置快照不算**——ETag 与强拉判定都以它为准。
    private var hasDiskCache: Bool {
        FileManager.default.fileExists(atPath: cacheFile.path)
    }

    /// 加固④：装载安装包内置快照兜底（build-app.sh 构建时从线上表 curl 生成，随 app 分发）。
    ///
    /// 只在**磁盘缓存不存在**时装（磁盘缓存更新、永远优先）。快照不写盘、不产生 ETag，
    /// 所以 `refreshIfNeeded` 仍会按「无磁盘缓存」无条件强拉——快照只负责消灭「全员 $0」，
    /// 不阻断价格更新。data 走 autoclosure：磁盘缓存在时压根不会去读那 330KB。
    @discardableResult
    public func installBundledSnapshotIfNeeded(_ data: @autoclosure () -> Data?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskLocked()
        guard flat.isEmpty else { return false }          // 已有磁盘缓存 → 快照不插手
        guard let d = data(), let parsed = Self.parse(d), parsed.count >= 30 else { return false }
        apply(parsed)
        usingSnapshot = true
        return true
    }

    /// 加固③：价目表新鲜度（设置页提示用）。表龄按磁盘缓存的 mtime 算。
    public func freshness() -> Freshness {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskLocked()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path))?[.modificationDate] as? Date
        // 从未成功落盘（nil）也算过期——这正是「拉取被拦、一直吃快照」的情形，必须提示
        let stale = mtime.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        return Freshness(lastUpdated: mtime, usingSnapshot: usingSnapshot, isStale: stale)
    }

    /// 同步装表（NSLock 不能在 async 上下文直接调，收进同步方法）
    private func install(_ table: [String: [String: Rate]]) {
        lock.lock()
        apply(table)
        diskLoaded = true
        usingSnapshot = false   // 已经是线上表了，不再是快照
        lock.unlock()
    }

    // MARK: - 解析 / 装载

    private struct Feed: Decodable {
        let providers: [String: [String: RawRate]]
    }

    private struct RawRate: Decodable {
        let input: Double?
        let output: Double?
        let cache_read: Double?
        let cache_write: Double?
    }

    /// data → provider→model→Rate；解析失败返回 nil
    static func parse(_ data: Data) -> [String: [String: Rate]]? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
        var out: [String: [String: Rate]] = [:]
        for (pid, models) in feed.providers {
            var m: [String: Rate] = [:]
            for (mid, raw) in models {
                m[mid] = Rate(input: raw.input ?? 0, output: raw.output ?? 0,
                              cacheRead: raw.cache_read ?? 0, cacheWrite: raw.cache_write ?? 0)
            }
            if !m.isEmpty { out[pid] = m }
        }
        return out
    }

    /// 建 byProvider + flat（canonical 渠道优先，其余按字母序，先写不覆盖）
    private func apply(_ table: [String: [String: Rate]]) {
        byProvider = table
        var f: [String: Rate] = [:]
        let ordered = Self.canonicalProviders.filter { table[$0] != nil }
            + table.keys.filter { !Self.canonicalProviders.contains($0) }.sorted()
        for pid in ordered {
            for (mid, r) in table[pid] ?? [:] where f[mid] == nil {
                f[mid] = r
            }
        }
        flat = f
    }

    private func loadFromDiskLocked() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let data = try? Data(contentsOf: cacheFile), let parsed = Self.parse(data) else { return }
        apply(parsed)
    }

    /// 单测注入用：直接灌表（绕过磁盘/网络）
    public func injectForTesting(_ json: Data) -> Bool {
        guard let parsed = Self.parse(json) else { return false }
        lock.lock()
        apply(parsed)
        diskLoaded = true
        lock.unlock()
        return true
    }
}
