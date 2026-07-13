import XCTest
@testable import usageBarCore

/// 「通用模型名不得跨 provider 撞名查价」回归锁（v0.3.22）。
///
/// 背景（两次踩坑，一次比一次隐蔽）：
/// 1. `auto` 是 Cursor / WorkBuddy / Qoder 共用的**路由名**（"自动选模型"），不是模型 id。
///    它先命中了远程价目表里毫不相干的 `llmgateway/auto`，单价是 `{input:0, output:0}` →
///    `rate != nil` → `hasNoPricing` 返回 false → UI **不弹「无价目」，把 $0 当真价静默显示**。
/// 2. 加了「零价命中不算数」的兜底后，查表**继续往下找**，`auto` 又滑到了 `morph/auto`——
///    这个**有价**！于是 Cursor 的 376 万 token 会按一个毫不相干服务的价格算钱，
///    **从"错成 $0"变成"错成一个有模有样的数字"，更危险**。
///
/// 结论：通用名在 154 个 provider 的价目表里**必然撞名**，只能在入口黑名单拦掉。
final class GenericModelPricingTests: XCTestCase {

    /// 路由名 / 套餐档位名 / 厂商打码名一律无价目 —— 绝不能算出一个"看着挺像"的金额。
    func testGenericAliasesNeverPriced() {
        // auto：Cursor / WorkBuddy / Qoder 的「自动选模型」路由名
        // ultimate / efficient / lite / performance：Qoder CLI 的**套餐档位名**（2026-07-13 实测）
        // qmodel / dmodel / kmodel / gm51model / qmodel_latest / qwork-auto：Qoder 的打码别名
        for m in ["auto", "AUTO", "Auto",
                  "ultimate", "efficient", "lite", "performance",
                  "qmodel", "qmodel_latest", "qwork-auto", "dmodel", "kmodel", "gm51model"] {
            XCTAssertTrue(UnifiedPricing.hasNoPricing(for: m),
                          "⛔ 回归：通用名 `\(m)` 又被查到价了 → 会按一个毫不相干的模型算钱")
            XCTAssertEqual(UnifiedPricing.inputRate(for: m), 0, "`\(m)` 不该有输入单价")
            XCTAssertEqual(UnifiedPricing.outputRate(for: m), 0, "`\(m)` 不该有输出单价")

            let t = TokenBreakdown(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
            XCTAssertEqual(UnifiedPricing.cost(t, modelId: m), 0,
                           "⛔ 回归：`\(m)` 算出了非 0 金额 —— 那个数字是编造的")
        }
    }

    /// 黑名单**只拦通用名**，别误伤真模型（尤其别把带这些词的真 id 也拦了）。
    func testRealModelsStillResolveOrFailHonestly() {
        // 这些是真模型 id 的形态：黑名单不该把它们当通用名拦掉。
        // （能不能查到价取决于远程表是否已加载，这里只断言"没被黑名单误杀"——
        //   即它们不在 genericAliases 里。）
        for m in ["claude-fable-5", "gpt-5.5", "claude-opus-4-7", "deepseek-v4-flash",
                  "claude-fable-5-thinking-high", "gpt-5.5-fast"] {
            XCTAssertFalse(UnifiedPricing.genericAliases.contains(m.lowercased()),
                           "⛔ 真模型 `\(m)` 被通用名黑名单误伤了")
        }
    }

    /// 尾段剥离仍要正常工作（Cursor 的模型名带 thinking/high 后缀，剥掉才命中真身）。
    func testSuffixStrippingStillWorks() {
        XCTAssertEqual(UnifiedPricing.candidates(for: "claude-fable-5-thinking-high"),
                       ["claude-fable-5-thinking-high", "claude-fable-5-thinking", "claude-fable-5"])
        XCTAssertEqual(UnifiedPricing.candidates(for: "gpt-5.5-fast"),
                       ["gpt-5.5-fast", "gpt-5.5"])
    }
}
