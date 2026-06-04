import Foundation
import SwiftUI
import usageBarCore

/// Provider 可见性设置(持久化到 UserDefaults)
///
/// 存储策略:存「禁用集合」而不是「启用集合」。
/// 理由:新出现的 provider id (比如未来加新 source 子项) 默认 ON,用 disabled set
/// 实现最自然 — 不在 set 里就是 enabled。
///
/// 单层语义(2026-05-25 简化):只有 provider id 一层开关,family 不暴露父级 Toggle,
/// 用户要"关掉整个 family"就把同组子项各自关掉(UI 用虚线框分组提示视觉关联)。
/// 之前 family 父级 Toggle + 子级独立可控的双层联动太重,删了。
///
/// 跨设备同步:当前只走 UserDefaults(本机 plist),未来需求详见
/// docs/cross-device-sync-design.md。
@MainActor
final class ProviderVisibilitySettings: ObservableObject {
    static let shared = ProviderVisibilitySettings()

    @Published private(set) var disabledProviders: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledProviders), forKey: Keys.disabledProviders)
        }
    }

    private enum Keys {
        static let disabledProviders = "usagebar.disabledProviders.v1"
    }

    private init() {
        let pd = UserDefaults.standard.array(forKey: Keys.disabledProviders) as? [String] ?? []
        self.disabledProviders = Set(pd)
    }

    // MARK: - 查询

    /// 该 provider 是否最终对用户可见
    func isVisible(provider: any UsageProvider) -> Bool {
        !disabledProviders.contains(provider.id)
    }

    /// Settings UI 用:provider 自己的 toggle 状态
    func isProviderToggleOn(_ id: String) -> Bool {
        !disabledProviders.contains(id)
    }

    /// 当前可见 provider id 列表(按 ProviderRegistry 注册顺序)
    func visibleProviderIds() -> [String] {
        ProviderRegistry.all
            .filter { isVisible(provider: $0) }
            .map { $0.id }
    }

    // MARK: - 改写

    func setProvider(_ id: String, enabled: Bool) {
        if enabled {
            disabledProviders.remove(id)
        } else {
            disabledProviders.insert(id)
        }
    }
}
