import Foundation

/// 远程价目层：`usagebar.cn/pricing.json`（服务器 cron 每日从 models.dev 全量瘦身生成，
/// 结构 `{"providers": {providerID: {modelID: {input/output/cache_read/cache_write}}}}`，
/// 单价 $/1M token，约 146 厂商 5000 模型）。
///
/// 角色（2026-07-12 起）：`UnifiedPricing` 的**唯一价源**——claude-*/gpt-* 也在这查
/// （内置手工价格表已退役，缘由见 `ModelPricing.swift` 头注 + `_notes/docs/0712-价格统一走远程表/`），
/// 查不到的真长尾按 $0 + 「无价目」引导。
///
/// 更新策略：每日一次 ETag 条件拉取（`refreshIfNeeded`，24h 节流，304 零流量），
/// 缓存在 Application Support；**本地无缓存（首启/被手删）时无视节流立即拉**，
/// 失败不记检查时间戳、下轮刷新循环自动重试，$0 窗口在联网时秒级自愈。
public final class RemotePricing: @unchecked Sendable {
    public static let shared = RemotePricing()

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

    /// 同名模型出现在多个渠道（如 openrouter 转售）时，优先采用官方渠道的价格
    private static let canonicalProviders = [
        "anthropic", "openai", "google", "zai", "deepseek",
        "alibaba", "moonshotai", "xai", "mistral",
    ]

    private static let feedURL = URL(string: "https://usagebar.cn/pricing.json")!
    private static let checkIntervalKey = "usagebar.pricingLastCheck.v1"
    private static let etagKey = "usagebar.pricingETag.v1"
    private static let checkInterval: TimeInterval = 24 * 3600

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
    /// 例外：本地一张表都没有（首启/缓存被手删）时无视节流立即拉——远程表是唯一价源，
    /// 没表就是全员 $0，早一轮拉到早一轮恢复。
    public func refreshIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: Self.checkIntervalKey)
        let throttled = Date().timeIntervalSince1970 - last < Self.checkInterval
        guard !throttled || !hasAnyData() else { return }

        var req = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return }  // 离线等失败静默,下轮再试

        // 无论 200/304 都记本次检查时间（304 = 已是最新）
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkIntervalKey)
        guard http.statusCode == 200 else { return }

        // 结构校验通过才落盘替换（防服务端残表把本地好缓存冲掉）
        guard let parsed = Self.parse(data), parsed.count >= 30 else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            UserDefaults.standard.set(etag, forKey: Self.etagKey)
        }
        install(parsed)
    }

    /// 是否已装载任何价目（含尝试读磁盘缓存）。同步方法收拢 NSLock（async 上下文不能直接调）。
    private func hasAnyData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskLocked()
        return !flat.isEmpty
    }

    /// 同步装表（NSLock 不能在 async 上下文直接调，收进同步方法）
    private func install(_ table: [String: [String: Rate]]) {
        lock.lock()
        apply(table)
        diskLoaded = true
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
