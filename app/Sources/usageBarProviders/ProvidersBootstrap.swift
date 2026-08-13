import Foundation
import usageBarCore

/// 把所有 provider 注册到 Core 的 Registry。
///
/// 主 App 启动时调用一次:`UsageBarProviders.registerAll()`。
///
/// 注册顺序 = UI 默认渲染顺序(Settings 关闭某项后该行不渲染,但顺序不变):
///   1. Claude 系(family="claude"):Claude Code → Cowork(共 2 个实例)
///   2. Qoder 系(family="qoder"):CLI → IDE(共 2 个实例)
///       - CLI 读 ~/.qoder/projects/.../*.jsonl(旧 transcript) + ~/.qoder/logs/sessions/**/segments/*.jsonl(新源)
///       - IDE 读 SharedClientCache SQLite(chat_message.token_info)
///       - ⚠️ QoderWork 已于 v0.3.33 下架(由千问办公替代),悟空同批下架
///   3. 千问办公(独立,读 ~/.qwenworkcn/logs/sessions/**/segments/*.jsonl)
///   4. Codex(独立)
///   5. WorkBuddy(独立,读 ~/.workbuddy/projects/.../*.jsonl 的 providerData.rawUsage)
///   6. Cursor(唯一联网) → OpenCode
///
/// ⚠️ **v0.3.33 下架了 4 个 provider**：QoderWork / 悟空(由千问办公替代)、
/// OpenClaw / Hermes Agent(本机未使用)。当前 9 个实例。
/// 下架 = 从本列表摘掉 + 删 provider 实现 + 清 UsageView 元信息/图标分支 + 清详情声明表；
/// 历史数据随 schemaVersion 9 的重扫一并清出,不留置灰行。
///
/// 固定 provider 列表，避免运行时动态发现的复杂度。
public enum UsageBarProviders {
    public static func registerAll() {
        let providers: [any UsageProvider] = [
            // Claude family
            ClaudeCodeProvider(),
            // Claude Cowork(桌面端,扫 local-agent-mode-sessions 下的 transcript)
            CoworkProvider(),
            // Qoder family(CLI/IDE 本地直读,零配置)
            QoderCliProvider(),
            QoderIdeProvider(),
            // 独立 provider
            QwenWorkProvider(),
            CodexProvider(),
            WorkBuddyProvider(),
            CursorProvider(),  // ⚠️ 唯一联网 provider（本地无真实 token，必须联网拉取）
            OpenCodeProvider(),
        ]

        ProviderRegistry.register(providers)
    }
}
