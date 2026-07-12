import Foundation

/// Claude 模型的命名与倍率常量。
///
/// ⚠️ 2026-07-12 起**价格表退役**：所有单价统一走 `UnifiedPricing`（一级价源 = 远程表，
/// 见 `RemotePricing`）。背景：内置手工表 cached 2026-07 没赶上 7/9 GA 的 gpt-5.6，
/// 等效花费显示成真实的 1/4；spec 见 `_notes/docs/0712-价格统一走远程表/`。
/// 这里只保留远程表给不了的两样：
///   1. `displayName`——model id → 友好名，纯命名、与价格无关；
///   2. `cacheWrite1hMul`——远程表 cache_write 只有 5m 档（input×1.25），
///      1h 档用 Anthropic 官方倍率 input×2 补出。
public enum ClaudePricing {

    /// 缓存写 1h 档相对 input 基准价的倍率（Anthropic 标准；5m 档远程表直接有价）
    public static let cacheWrite1hMul = 2.0

    /// model id → 友好名："claude-opus-4-8" → "Opus 4.8"，"claude-sonnet-4-6" → "Sonnet 4.6"。
    /// 取首个含字母的段作 family、其余纯数字段拼成版本号。
    public static func displayName(for modelId: String) -> String {
        var s = modelId
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        let toks = s.split(separator: "-").map(String.init)
        guard !toks.isEmpty else { return modelId }
        let fam = toks.first { $0.contains(where: { $0.isLetter }) } ?? toks[0]
        // 只取 ≤2 位的数字段当版本号（"4"/"8"），滤掉 8 位日期后缀（"20251001"）
        let nums = toks.filter { !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isNumber } }
        let family = fam.prefix(1).uppercased() + fam.dropFirst()
        let vers = nums.joined(separator: ".")
        return vers.isEmpty ? family : "\(family) \(vers)"
    }
}

/// Codex (OpenAI) 模型的命名工具。价格表已退役（缘由见 `ClaudePricing` 头注），只留 displayName。
public enum CodexPricing {

    /// model id → 友好名："gpt-5.5" → "GPT-5.5"，"gpt-5-codex" → "GPT-5-Codex"，"o4-mini" → "o4-mini"。
    public static func displayName(for modelId: String) -> String {
        guard !modelId.isEmpty else { return "未知模型" }
        let parts = modelId.split(separator: "-").map { (tok: Substring) -> String in
            let s = String(tok)
            if s.lowercased() == "gpt" { return "GPT" }
            if s.lowercased() == "codex" { return "Codex" }
            return s
        }
        return parts.joined(separator: "-")
    }
}

/// 跨厂商统一查价（等效 API 价）：**唯一入口，一级价源 = 远程表**（2026-07-12 拍板，
/// spec 见 `_notes/docs/0712-价格统一走远程表/`）。
///
/// 查价顺序：
///   1. id 规整：别名映射（models.dev 根本没有的内部别名 → 有价真身，如 codex-auto-review）；
///   2. 查 `RemotePricing`（约 150 厂商 5000 模型）——精确 id 未命中时依次退化：
///      去 `-YYYYMMDD` 日期后缀 → 逐段剥**纯字母**尾段（"-fast" 这类服务档位变体，最多 2 段）。
///      纯数字尾段绝不剥：claude-opus-4-8 剥成 claude-opus-4 就串到别的模型价了；
///   3. 都查不到按 0 计（宁显 $0 不猜价，UI 侧配「无价目」反馈引导）。
///
/// `provider` 选传（opencode 落库带 providerID）：远程表按 (provider, model) 精确匹配，
/// 同名模型多渠道价不同时不会取错；不传则按 claude-*/gpt-* 推断官方渠道。
public enum UnifiedPricing {

    /// models.dev 没有的内部别名 → 有价真模型 id
    static let aliases: [String: String] = [
        "codex-auto-review": "gpt-5.3-codex",
        "claude-mythos-5": "claude-fable-5",
    ]

    public static func inputRate(for modelId: String, provider: String? = nil) -> Double {
        (rate(modelId, provider)?.input ?? 0) / 1_000_000
    }

    public static func outputRate(for modelId: String, provider: String? = nil) -> Double {
        (rate(modelId, provider)?.output ?? 0) / 1_000_000
    }

    /// 缓存读单价（远程表的 cache_read 本身就是折后价）
    public static func cacheReadRate(for modelId: String, provider: String? = nil) -> Double {
        (rate(modelId, provider)?.cacheRead ?? 0) / 1_000_000
    }

    /// 缓存写单价（5m 档 = 远程表 cache_write 原值）
    public static func cacheWrite5mRate(for modelId: String, provider: String? = nil) -> Double {
        (rate(modelId, provider)?.cacheWrite ?? 0) / 1_000_000
    }

    /// 缓存写单价（1h 档）：只存在于 Anthropic 直连，远程表没这档，用官方倍率×远程 input 底价补；
    /// 非 Claude 本就不产生 1h token，按 5m 档价兜住口径。
    public static func cacheWrite1hRate(for modelId: String, provider: String? = nil) -> Double {
        guard let r = rate(modelId, provider) else { return 0 }
        return (isClaude(modelId) ? r.input * ClaudePricing.cacheWrite1hMul : r.cacheWrite) / 1_000_000
    }

    /// 等效 API 花费（美元）。output 需已含 reasoning（app 统一口径：reasoning ⊂ output）。
    public static func cost(_ t: TokenBreakdown, modelId: String, provider: String? = nil) -> Double {
        Double(t.input) * inputRate(for: modelId, provider: provider)
            + Double(t.output) * outputRate(for: modelId, provider: provider)
            + Double(t.cacheRead) * cacheReadRate(for: modelId, provider: provider)
            + Double(t.cacheCreate5m) * cacheWrite5mRate(for: modelId, provider: provider)
            + Double(t.cacheCreate1h) * cacheWrite1hRate(for: modelId, provider: provider)
    }

    /// 该模型是否完全无价可依（别名/归一化后远程表仍没有）→ UI「无价目」反馈引导用
    public static func hasNoPricing(for modelId: String, provider: String? = nil) -> Bool {
        rate(modelId, provider) == nil
    }

    // MARK: - 查表

    private static func rate(_ modelId: String, _ provider: String?) -> RemotePricing.Rate? {
        for id in candidates(for: modelId) {
            if let r = RemotePricing.shared.rate(provider: provider ?? providerHint(id), model: id) {
                return r
            }
        }
        return nil
    }

    /// 查价候选 id 序列：别名真身 → 去日期后缀 → 逐段剥纯字母尾段（最多 2 段）
    static func candidates(for modelId: String) -> [String] {
        var id = aliases[modelId.lowercased()] ?? modelId
        var out = [id]
        if let r = id.range(of: "-\\d{8}$", options: .regularExpression) {
            id = String(id[..<r.lowerBound])
            out.append(id)
        }
        for _ in 0..<2 {
            let segs = id.split(separator: "-")
            guard segs.count > 1, let last = segs.last, last.allSatisfy({ $0.isLetter }) else { break }
            id = segs.dropLast().joined(separator: "-")
            out.append(id)
        }
        return out
    }

    /// 官方渠道提示：同名模型出现在转售渠道（openrouter 等）时保证取官方价
    static func providerHint(_ m: String) -> String? {
        if isClaude(m) { return "anthropic" }
        if isOpenAI(m) { return "openai" }
        return nil
    }

    static func isClaude(_ m: String) -> Bool { m.hasPrefix("claude-") }
    static func isOpenAI(_ m: String) -> Bool { m.hasPrefix("gpt-") || m.hasPrefix("o3") || m.hasPrefix("o4") }
}
