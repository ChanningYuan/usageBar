import Foundation

/// Claude 各模型定价（$/1M token）+ 缓存倍率 → 「等效 API 花费」估算。
///
/// 订阅口径展示的「≈$」= 把该用量按官方 API 价折算的等效费用（并非真实扣费）；
/// claude-api 变体则接近真实费用。两者共用同一张表。
///
/// 数据源：claude-api skill 定价表（cached 2026-06-24）。
///   opus 4.x   $5 / $25    sonnet 4.6/5 $3 / $15
///   haiku 4.5  $1 / $5     fable/mythos 5 $10 / $50
///
/// 缓存倍率（相对 input 基准价，Anthropic 标准）：
///   命中读 0.1×、缓存写 5m 1.25×、缓存写 1h 2×、输出用 output 价。
public enum ClaudePricing {

    /// (输入 $/1M, 输出 $/1M)
    struct Rate {
        let input: Double
        let output: Double
    }

    public static let cacheReadMul = 0.1
    public static let cacheWrite5mMul = 1.25
    public static let cacheWrite1hMul = 2.0

    /// 某模型的 input 单价（$/token）
    public static func inputRate(for modelId: String) -> Double { rate(for: modelId).input / 1_000_000 }
    /// 某模型的 output 单价（$/token）
    public static func outputRate(for modelId: String) -> Double { rate(for: modelId).output / 1_000_000 }

    /// 按 model id 关键字匹配（model 形如 "claude-opus-4-8" / "claude-sonnet-4-6"）。
    /// 未知模型按 opus 价兜底（宁可略高不漏算）。
    static func rate(for modelId: String) -> Rate {
        let m = modelId.lowercased()
        if m.contains("haiku")  { return Rate(input: 1,  output: 5) }
        if m.contains("sonnet") { return Rate(input: 3,  output: 15) }
        if m.contains("opus")   { return Rate(input: 5,  output: 25) }
        if m.contains("fable") || m.contains("mythos") { return Rate(input: 10, output: 50) }
        return Rate(input: 5, output: 25)
    }

    /// 等效 API 花费（美元）。
    public static func cost(_ t: TokenBreakdown, modelId: String) -> Double {
        let r = rate(for: modelId)
        let inRate = r.input / 1_000_000
        let outRate = r.output / 1_000_000
        return Double(t.input)         * inRate
             + Double(t.output)        * outRate
             + Double(t.cacheRead)     * inRate * cacheReadMul
             + Double(t.cacheCreate5m) * inRate * cacheWrite5mMul
             + Double(t.cacheCreate1h) * inRate * cacheWrite1hMul
    }

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

/// Codex (OpenAI) 各模型定价（$/1M token）→ 「等效 API 花费」估算。
///
/// Codex 用 ChatGPT 订阅（plan_type=plus）跑，展示的「≈$」是按官方 API 价折算的等效费用（非真实扣费）。
///
/// 数据源：OpenAI 官方 API 定价（cached 2026-07，https://developers.openai.com/api/docs/pricing）：
///   gpt-5.5 $5/$30   gpt-5.4 $2.5/$15   gpt-5.x-codex $1.75/$14
///   gpt-5   $1.25/$10  o4-mini $1.1/$4.4  o3 $2/$8
///
/// 缓存输入折扣：OpenAI prompt caching 命中的 `cached_input_tokens` 按 ~0.1× input 价计（90% off）。
/// 思考 `reasoning_output_tokens` 已含在 `output_tokens` 内、按 output 价计（不额外加）。
public enum CodexPricing {

    struct Rate {
        let input: Double
        let output: Double
    }

    /// 缓存命中输入相对 input 基准价的倍率（OpenAI ~90% 折扣）。
    public static let cachedInputMul = 0.1

    public static func inputRate(for modelId: String) -> Double { rate(for: modelId).input / 1_000_000 }
    public static func outputRate(for modelId: String) -> Double { rate(for: modelId).output / 1_000_000 }

    /// 按 model id 关键字匹配（"gpt-5.5" / "gpt-5-codex" / "o4-mini" …）。codex 变体优先判定。
    /// 未知模型按 gpt-5.5 兜底（宁可略高不漏算）。
    static func rate(for modelId: String) -> Rate {
        let m = modelId.lowercased()
        if m.contains("codex") { return Rate(input: 1.75, output: 14) }
        if m.contains("5.5")   { return Rate(input: 5,    output: 30) }
        if m.contains("5.4")   { return Rate(input: 2.5,  output: 15) }
        if m.contains("o4")    { return Rate(input: 1.1,  output: 4.4) }
        if m.contains("o3")    { return Rate(input: 2,    output: 8) }
        if m.contains("gpt-5") || m.contains("5") { return Rate(input: 1.25, output: 10) }
        return Rate(input: 5, output: 30)
    }

    /// 等效 API 花费（美元）。TokenBreakdown 走 Codex 口径：input=净输入, cacheRead=缓存命中, output=输出（含 reasoning）。
    public static func cost(_ t: TokenBreakdown, modelId: String) -> Double {
        let r = rate(for: modelId)
        let inRate = r.input / 1_000_000
        let outRate = r.output / 1_000_000
        return Double(t.input)     * inRate
             + Double(t.cacheRead) * inRate * cachedInputMul
             + Double(t.output)    * outRate
    }

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
