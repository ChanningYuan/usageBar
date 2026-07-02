import Foundation
import SwiftUI
import usageBarCore

/// popover 顶部「时间标签」栏的用户配置（持久化到 UserDefaults）。
///
/// 模型 = 一份**有序候选清单** `order`（全部 7 个周期）+ **勾选集** `checked`（哪些作为 tab 显示）。
/// popover 的实际 tab = `order` 里被勾选的项，按 `order` 顺序（`tabOrder`）。
///
/// 不变量：
/// - `"today"` 恒在 `order[0]`、恒在 `checked`、不可取消/不可拖（常驻锚点）。
/// - 勾选数 ≤ `maxTabs`（4）——受 popover 宽度约束；勾第 5 个被拒并闪 `limitHit`。
/// - `"custom"` 只有在 `customRange` 有效时才真正进 `tabOrder`。
///
/// 配置 UI 在**设置弹窗**（真 NSWindow，无 NSPopover 失焦坑），见 SettingsView「时间标签」分组。
@MainActor
final class TabSettings: ObservableObject {
    static let shared = TabSettings()

    static let maxTabs = 4
    /// 全部候选（也是"从未存过配置"时的默认顺序）。
    /// v0.3.13 默认标签＝今日/本周/本月/累计（日历对齐比滚动近7/近30 更贴"这周/这月"直觉）；
    /// 故把 thisWeek/thisMonth 排在 all 前、近7/近30 靠后当备选。绝大多数从 v0.3.12 升级的用户
    /// 没有 TabSettings 存档，走此默认。
    static let allCandidates = ["today", "thisWeek", "thisMonth", "all", "last7Days", "last30Days", "custom"]
    static let defaultChecked: Set<String> = ["today", "thisWeek", "thisMonth", "all"]

    @Published var order: [String] { didSet { UserDefaults.standard.set(order, forKey: Keys.order) } }
    @Published private(set) var checked: Set<String> { didSet { UserDefaults.standard.set(Array(checked), forKey: Keys.checked) } }
    @Published var weekStartMonday: Bool { didSet { UserDefaults.standard.set(weekStartMonday, forKey: Keys.weekStart) } }
    @Published var customLo: Date? { didSet { UserDefaults.standard.set(customLo, forKey: Keys.customLo) } }
    @Published var customHi: Date? { didSet { UserDefaults.standard.set(customHi, forKey: Keys.customHi) } }
    /// 勾选超过上限时置 true 让 UI 闪一下提示；UI 消费后自行复位
    @Published var limitHit: Bool = false

    private enum Keys {
        static let order = "usagebar.tabOrder.v1"
        static let checked = "usagebar.tabChecked.v1"
        static let weekStart = "usagebar.weekStartMonday.v1"
        static let customLo = "usagebar.customLo.v1"
        static let customHi = "usagebar.customHi.v1"
    }

    private init() {
        let d = UserDefaults.standard
        // order：读回后补全缺失候选（未来加新周期也不丢）、去重、today 置顶
        var loaded = (d.array(forKey: Keys.order) as? [String]) ?? Self.allCandidates
        loaded = loaded.filter { Self.allCandidates.contains($0) }
        for c in Self.allCandidates where !loaded.contains(c) { loaded.append(c) }
        self.order = Self.pinTodayFirst(loaded)

        // checked：首次（无存档）用默认 4 个
        if let arr = d.array(forKey: Keys.checked) as? [String] {
            var s = Set(arr.filter { Self.allCandidates.contains($0) })
            s.insert("today")
            self.checked = s
        } else {
            self.checked = Self.defaultChecked
        }

        self.weekStartMonday = d.object(forKey: Keys.weekStart) as? Bool ?? true
        self.customLo = d.object(forKey: Keys.customLo) as? Date
        self.customHi = d.object(forKey: Keys.customHi) as? Date
    }

    // MARK: - 派生

    /// popover 实际要渲染的 tab id 序列（勾选 ∩ order 顺序；custom 需区间有效）
    var tabOrder: [String] {
        order.filter { id in
            guard checked.contains(id) else { return false }
            if id == "custom" { return customRange != nil }
            return true
        }
    }

    var customRange: ClosedRange<Date>? {
        guard let lo = customLo, let hi = customHi, lo <= hi else { return nil }
        return lo...hi
    }

    func isChecked(_ id: String) -> Bool { checked.contains(id) }

    /// 已勾选（且有效）计数——用于"已选 n/4"
    var selectedCount: Int { tabOrder.count }

    // MARK: - 改写

    /// 勾选/取消一个候选。today 不可取消；勾选达上限则拒绝并闪提示。返回是否成功。
    @discardableResult
    func toggle(_ id: String, on: Bool) -> Bool {
        if id == "today" { return false }  // 恒勾选
        if on {
            guard checked.count < Self.maxTabs else { limitHit = true; return false }
            checked.insert(id)
        } else {
            checked.remove(id)
        }
        return true
    }

    /// 拖拽重排候选清单；重排后强制 today 回到首位。
    func move(from source: IndexSet, to destination: Int) {
        var arr = order
        arr.move(fromOffsets: source, toOffset: destination)
        order = Self.pinTodayFirst(arr)
    }

    /// onDrag/onDrop 重排：把 `dragging` 放到 `target` 的位置（today 不参与、重排后 today 回首位）。
    func reorder(_ dragging: String, onto target: String) {
        guard dragging != "today", target != "today", dragging != target else { return }
        guard let from = order.firstIndex(of: dragging), let to = order.firstIndex(of: target) else { return }
        var arr = order
        let moved = arr.remove(at: from)
        let newTo = arr.firstIndex(of: target) ?? arr.count
        arr.insert(moved, at: from < to ? newTo + 1 : newTo)
        order = Self.pinTodayFirst(arr)
    }

    private static func pinTodayFirst(_ arr: [String]) -> [String] {
        var a = arr
        if let i = a.firstIndex(of: "today"), i != 0 {
            a.remove(at: i)
            a.insert("today", at: 0)
        } else if !a.contains("today") {
            a.insert("today", at: 0)
        }
        return a
    }
}
