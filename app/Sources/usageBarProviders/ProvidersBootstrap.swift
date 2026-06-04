import Foundation
import usageBarCore

/// 把所有 provider 注册到 Core 的 Registry。
///
/// 主 App 启动时调用一次:`UsageBarProviders.registerAll()`。
///
/// 注册顺序 = UI 默认渲染顺序(Settings 关闭某项后该行不渲染,但顺序不变):
///   1. Claude 系(family="claude"):订阅 → cc-api(共 2 个实例)
///   2. Qoder 系(family="qoder"):CLI → Work → IDE(共 3 个实例)
///       - CLI 读 ~/.qoder/projects/.../*.jsonl(transcript)
///       - Work 读 main.log → 本地 mirror jsonl(纯本地直读)
///       - IDE 读 SharedClientCache SQLite(chat_message.token_info)
///   3. Codex(独立)
///   4. 悟空(独立)
///   5. WorkBuddy(独立,读 ~/.workbuddy/projects/.../*.jsonl 的 providerData.rawUsage)
///
/// 共 2 + 3 + 1 + 1 + 1 = 8 个 provider。
/// Claude 2 个实例共享 ClaudeJsonlScanner,
/// Qoder CLI / Work / IDE 数据源各不同,各自独立扫描无需共享 scanner;单次 refresh 各 provider
/// 只扫自己的数据源一次。
///
/// 固定列表风格与 ClaudeCodeVariant 一致(避免运行时动态发现的复杂度)。
public enum UsageBarProviders {
    public static func registerAll() {
        let providers: [any UsageProvider] = [
            // Claude family(按 message.id 前缀拆 2 行)
            ClaudeCodeProvider(variant: .subscription),
            ClaudeCodeProvider(variant: .api),
            // Qoder family(三件套全部本地直读,零配置)
            QoderCliProvider(),
            QoderWorkProvider(),
            QoderIdeProvider(),
            // 独立 provider
            CodexProvider(),
            WukongProvider(),
            WorkBuddyProvider(),
            CursorProvider(),  // ⚠️ 唯一联网 provider，勾选即联网拉取
            OpenClawProvider(),
            HermesProvider(),
            // TODO: TongyiProvider(IndexedDB,无法解析)
        ]

        ProviderRegistry.register(providers)
    }
}
