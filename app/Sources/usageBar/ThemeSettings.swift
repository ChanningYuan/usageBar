import AppKit
import SwiftUI

/// 弹层 / 设置窗的外观主题：深色 / 浅色 / 跟随系统。
/// 用 `NSApp.appearance` 全局生效（菜单栏弹层 + 设置窗 + 右键菜单都跟随），持久化到 UserDefaults。
enum AppTheme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()
    private static let key = "usagebar.theme.v1"

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.key)
            applyToApp()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppTheme.system.rawValue
        self.theme = AppTheme(rawValue: raw) ?? .system
    }

    /// 把当前主题应用到整个 app（`NSApp.appearance`）。启动时 AppDelegate 调一次，之后 didSet 自动跟。
    func applyToApp() {
        NSApp.appearance = theme.nsAppearance
    }
}
