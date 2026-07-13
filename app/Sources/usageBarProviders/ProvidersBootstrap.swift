import Foundation
import usageBarCore

/// 把所有 provider 注册到 Core 的 Registry。
///
/// 主 App 启动时调用一次:`UsageBarProviders.registerAll()`。
///
/// 注册顺序 = UI 默认渲染顺序(Settings 关闭某项后该行不渲染,但顺序不变):
///   1. Claude 系(family="claude"):Claude Code → Cowork(共 2 个实例)
///   2. Qoder 系(family="qoder"):CLI → Work → IDE(共 3 个实例)
///       - CLI 读 ~/.qoder/projects/.../*.jsonl(transcript)
///       - Work 读 ~/.qoderwork/projects transcript(0.6.3 起) + 旧 main.log mirror(历史,冻结)
///       - IDE 读 SharedClientCache SQLite(chat_message.token_info)
///   3. Codex(独立)
///   4. 悟空(独立)
///   5. WorkBuddy(独立,读 ~/.workbuddy/projects/.../*.jsonl 的 providerData.rawUsage)
///
/// 固定 provider 列表，避免运行时动态发现的复杂度。
public enum UsageBarProviders {
    public static func registerAll() {
        let providers: [any UsageProvider] = [
            // Claude family
            ClaudeCodeProvider(),
            // Claude Cowork(桌面端,扫 local-agent-mode-sessions 下的 transcript)
            CoworkProvider(),
            // Qoder family(三件套全部本地直读,零配置)
            QoderCliProvider(),
            QoderWorkProvider(),
            QoderIdeProvider(),
            // 独立 provider
            CodexProvider(),
            WukongProvider(),
            WorkBuddyProvider(),
            CursorProvider(),  // ⚠️ 唯一联网 provider（本地无真实 token，必须联网拉取）
            OpenClawProvider(),
            HermesProvider(),
            OpenCodeProvider(),
            // TODO: TongyiProvider(IndexedDB,无法解析)
        ]

        ProviderRegistry.register(providers)
    }
}
