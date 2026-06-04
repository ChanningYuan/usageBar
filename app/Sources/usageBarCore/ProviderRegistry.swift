import Foundation

/// Provider 注册中心。主 App 从这里取列表。
///
/// 实际的 provider 实现住在 `usageBarProviders` module，
/// 但注册由 `usageBarProviders.registerAll()` 完成（避免 Core 反向依赖 Providers）。
public enum ProviderRegistry {
    nonisolated(unsafe) private static var registered: [any UsageProvider] = []
    private static let lock = NSLock()

    public static func register(_ providers: [any UsageProvider]) {
        lock.lock(); defer { lock.unlock() }
        registered = providers
    }

    public static var all: [any UsageProvider] {
        lock.lock(); defer { lock.unlock() }
        return registered
    }
}
