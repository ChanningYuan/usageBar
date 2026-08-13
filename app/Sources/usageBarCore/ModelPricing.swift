import Foundation

/// Claude 计价中远程表无法表达的倍率常量。
///
/// ⚠️ 2026-07-12 起所有单价统一走 `UnifiedPricing`（一级价源 = 远程表，
/// 见 `RemotePricing`）。远程表 cache_write 只有 5m 档（input×1.25），
/// 1h 档用 Anthropic 官方倍率 input×2 补出。
public enum ClaudePricing {

    /// 缓存写 1h 档相对 input 基准价的倍率（Anthropic 标准；5m 档远程表直接有价）
    public static let cacheWrite1hMul = 2.0
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

    /// **通用名 / 厂商打码名黑名单：一律不查表，直接判无价目。**
    ///
    /// 这些不是模型 id，而是「路由名」或「套餐档位名」：
    /// - `auto` —— Cursor / WorkBuddy / Qoder 都用它表示「自动选模型」。真实成本取决于当时选中的是谁，
    ///   我们无从得知 → **无价目才是诚实的**。
    /// - `ultimate` / `efficient` / `lite` / `performance` —— Qoder CLI 的**套餐档位名**（2026-07-13 实测）
    /// - `qmodel` / `qmodel_latest` / `qwork-auto` / `qwork-advanced` / `dmodel` / `dmodel_latest`
    ///   / `kmodel` / `gm51model` / `cmodel` —— Qoder 系（含千问办公）的打码别名。
    ///   ⚠️ 厂商会不定期新增：2026-08-14 千问办公 0.1.7 就冒出了 `qwork-advanced` / `dmodel_latest`。
    ///   发现日志里出现没见过的打码名，补进这里，否则会去价目表里撞名（见下方警告）。
    ///
    /// ⚠️ **为什么必须黑名单、而不能靠"查不到就算了"**：`auto` 这种大众名字在 154 个 provider 的
    /// 价目表里**必然撞名**。实测它先命中 `llmgateway/auto`（单价全 0 → 静默显示 $0），
    /// 加了「零价不算数」的兜底后又滑到 `morph/auto`（**有价**！）—— 于是 Cursor 的 376 万 token
    /// 会被按一个毫不相干的服务的价格算钱，**从"错成 $0"变成"错成一个有模有样的数字"，更危险**。
    /// 通用名撞名是结构性的，只能在入口拦掉。
    static let genericAliases: Set<String> = [
        "auto",
        "ultimate", "efficient", "lite", "performance",
        "qmodel", "qmodel_latest", "qwork-auto", "qwork-advanced",
        "dmodel", "dmodel_latest", "kmodel", "gm51model", "cmodel",
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

    /// 该模型是否完全无价可依（别名/归一化后远程表仍没有，**或命中了但单价全 0**）→ UI「无价目」反馈引导用。
    ///
    /// ⚠️ v0.3.22 修复（线上现存 bug，v0.3.21 就有）：**「命中但单价全 0」以前被当成有价**。
    /// 典型是模型名 `auto` —— Cursor / WorkBuddy 都用它，而远程价目表里恰好有个
    /// **毫不相干**的 `llmgateway/auto`（另一家服务的路由模型），单价是 `{input: 0, output: 0}`。
    /// 于是 `rate != nil` → `hasNoPricing` 返回 false → UI **不弹「无价目」，而是把 `$0` 当成真价静默显示**。
    /// 用户看到 $0 会以为免费/极便宜，实际是查错了表。影响面：Cursor 的 `auto`（实测 376 万 token）、
    /// WorkBuddy 的全部用量。详情页会把这个假 $0 **逐行放大展示**（按模型/按会话每行都有金额列），故本版必修。
    ///
    /// 修法是通用兜底：**单价全 0 的命中一律视为无价**（真·免费模型不存在；全 0 只可能是查错表或数据缺失）。
    public static func hasNoPricing(for modelId: String, provider: String? = nil) -> Bool {
        guard let r = rate(modelId, provider) else { return true }
        return r.input == 0 && r.output == 0 && r.cacheRead == 0 && r.cacheWrite == 0
    }

    // MARK: - 查表

    private static func rate(_ modelId: String, _ provider: String?) -> RemotePricing.Rate? {
        // 通用路由名 / 厂商打码名：入口直接拦掉，绝不进表（见 `genericAliases` 的说明）。
        // 不拦的话它们必然在 154 个 provider 的表里撞名，算出一个"有模有样但完全错误"的金额。
        if genericAliases.contains(modelId.lowercased()) { return nil }

        for id in candidates(for: modelId) {
            if let r = RemotePricing.shared.rate(provider: provider ?? providerHint(id), model: id) {
                // 单价全 0 的命中不算数（见 `hasNoPricing`）——继续找下一个候选 id。
                if r.input == 0 && r.output == 0 && r.cacheRead == 0 && r.cacheWrite == 0 { continue }
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
