import Foundation
import SwiftUI

/// 后台自动刷新频率（分钟），设置页「通用」段滑轨调节。
/// 范围 1–15 分钟，默认 10（mtime 增量后单次刷新成本低，但仍避免默认高频）。
@MainActor
final class RefreshIntervalSettings: ObservableObject {
    static let shared = RefreshIntervalSettings()
    private static let key = "usagebar.refreshInterval.minutes.v1"

    static let range = 1...15
    static let defaultMinutes = 10

    @Published var minutes: Int {
        didSet {
            UserDefaults.standard.set(minutes, forKey: Self.key)
        }
    }

    var interval: TimeInterval { TimeInterval(minutes * 60) }

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Self.key)
        self.minutes = Self.range.contains(saved) ? saved : Self.defaultMinutes
    }
}
