import AppKit
import SwiftUI
import UniformTypeIdentifiers
import usageBarCore
import usageBarProviders

/// popover「＋自定义」入口 → 打开设置并聚焦「时间周期标签」段的导航信号。
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    /// 置 true 表示"打开设置后应展开并滚到时间周期标签段"；SettingsView 消费后复位。
    @Published var pendingFocusTimeTabs = false
    func requestFocusTimeTabs() { pendingFocusTimeTabs = true }
}

/// Settings 面板(右键菜单 → 偏好设置...)
///
/// 形态:family 用虚线圆角框包起来,标题压在虚线边上(类似 HTML fieldset);
/// 独立 provider(Codex/悟空)不框,直接平铺。无父级 Toggle — 用户要"关 family 整组"
/// 自己把子项各自关掉即可(UI 视觉用虚线框提示同组关联)。
struct SettingsView: View {
    @ObservedObject var settings: ProviderVisibilitySettings
    @ObservedObject private var qoderStatus: QoderUsageStatus = .shared
    @ObservedObject private var tabSettings: TabSettings = .shared
    @ObservedObject private var themeSettings: ThemeSettings = .shared
    @ObservedObject private var nav = SettingsNavigation.shared
    @State private var draggingTab: String?
    @State private var dataSourceExpanded = true
    @State private var tabsExpanded = true

    /// GitHub mark(模板图,跟随主题/链接色)
    private static let githubIcon: NSImage? = {
        guard let img = BundleIconLoader.load(name: "github", ext: "svg") else { return nil }
        img.isTemplate = true
        return img
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        appearanceSection
                        Divider()
                        dataSourceSection
                        Divider()
                        timeTabsSection.id("timeTabs")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: nav.pendingFocusTimeTabs) { _, focus in
                    if focus { focusTimeTabs(proxy) }
                }
                .onAppear {
                    // 窗口首次创建：SettingsView 才 appear，此时消费待聚焦请求
                    if nav.pendingFocusTimeTabs { focusTimeTabs(proxy) }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { qoderStatus.refresh() }
    }

    // MARK: - Header / Footer

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .medium))
            Text("usageBar 偏好设置")
                .font(.system(size: 13, weight: .semibold))
            Text("v\(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text("提示:勾选状态实时生效,弹层会自动刷新。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: {
                if let url = URL(string: "https://github.com/ChanningYuan/usageBar") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    if let img = Self.githubIcon {
                        Image(nsImage: img)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                    }
                    Text("在 GitHub 点个 Star")
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.link)
            .help("在 GitHub 上点个 Star ⭐")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 「＋自定义」入口触发：展开时间周期标签段并滚动到它，然后复位信号。
    private func focusTimeTabs(_ proxy: ScrollViewProxy) {
        tabsExpanded = true
        // 等展开 + 布局完成后再滚，确保目标已进布局树
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo("timeTabs", anchor: .top) }
        }
        nav.pendingFocusTimeTabs = false
    }

    // MARK: - 折叠段通用

    private var visibleProviderCount: Int {
        ProviderRegistry.all.filter { settings.isProviderToggleOn($0.id) }.count
    }
    private var lastQoderId: String? {
        ProviderRegistry.all.last { $0.family == "qoder" }?.id
    }

    /// 折叠段标题行：chevron（收起▸ / 展开▾）+ 标题 + 右侧计数；整行可点击折叠。
    private func sectionHeader(_ title: String, count: String, expanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(count)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 外观（主题）

    /// 外观主题：深色 / 浅色 / 跟随系统（segmented，实时生效）
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("外观 · 主题")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Picker("", selection: $themeSettings.theme) {
                ForEach(AppTheme.allCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            .padding(.leading, 2)
        }
    }

    // MARK: - 数据源（provider 折叠段）

    /// 数据源折叠段：展开后内联各 provider（icon + 名称 + 开关）。Qoder 组前挂 token gate banner、
    /// Cursor 行下挂联网说明——与旧 family 框逻辑一致，只是从虚线框改成平铺 + 折叠。
    private var dataSourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("数据源", count: "已启用 \(visibleProviderCount) 个", expanded: dataSourceExpanded) {
                dataSourceExpanded.toggle()
            }
            if dataSourceExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ProviderRegistry.all, id: \.id) { p in
                        providerRow(p)
                        // Qoder gate banner 挂在 Qoder 系列**最后一行之后**（挂在最前会紧贴 Claude、被误认成 Claude 的）
                        if p.id == lastQoderId {
                            QoderUsageBanner(status: qoderStatus)
                        }
                        if p.id == "cursor" {
                            Text("Cursor 真实用量只在服务端，需联网获取：勾选后每次刷新会读取本机 Cursor 登录凭证并请求 cursor.com。不想联网就取消勾选。")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 32)
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
    }

    /// 单个 provider 行：icon + 名称 + 开关（switch）。
    private func providerRow(_ p: any UsageProvider) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(providerId: p.id)
                .frame(width: 22, height: 22)
            Text(p.displayName)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.isProviderToggleOn(p.id) },
                set: { settings.setProvider(p.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color(hex: "#007AFF"))  // 开启态用系统蓝
        }
        .frame(height: 30)
    }

    // MARK: - 时间标签（popover tab 栏配置，折叠段）

    /// 时间标签折叠段：展开后勾选哪些周期作为 popover tab + 拖拽排序 + 本周周起始 + 自定义区间。
    private var timeTabsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("时间周期标签", count: tabSettings.tabOrder.map { tabLabel($0) }.joined(separator: " | "), expanded: tabsExpanded) {
                tabsExpanded.toggle()
            }
            if tabsExpanded {
                Text("勾选显示在弹层顶部的时间周期标签 · 拖动排序 · 最多 \(TabSettings.maxTabs) 个")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)

                VStack(spacing: 0) {
                    ForEach(Array(tabSettings.order.enumerated()), id: \.element) { idx, id in
                        timeTabRow(id)
                        if idx < tabSettings.order.count - 1 { Divider() }
                    }
                }
                .padding(.leading, 2)

                let cnt = tabSettings.checked.count
                Text("已选 \(cnt)/\(TabSettings.maxTabs)" + (cnt >= TabSettings.maxTabs ? " · 已满，取消一个再加" : ""))
                    .font(.system(size: 9))
                    .foregroundStyle(cnt >= TabSettings.maxTabs ? .orange : .secondary)
                    .padding(.leading, 2)
            }
        }
    }

    /// 一行候选：拖拽手柄 + 勾选框 + 名称 +（本周周起始 / 自定义区间编辑）；today 锁定不可拖/不可取消。
    @ViewBuilder
    private func timeTabRow(_ id: String) -> some View {
        HStack(spacing: 8) {
            // 拖拽手柄槽：today 隐藏（占位保持对齐），其余显示 grip 提示可拖
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
                .opacity(id == "today" ? 0 : 1)

            Toggle(isOn: Binding(
                get: { tabSettings.isChecked(id) },
                set: { on in
                    // 勾「自定义区间」且尚无区间时，播种默认区间（近 7 天）让 tab 立即可见
                    if id == "custom", on, tabSettings.customRange == nil {
                        if tabSettings.customLo == nil {
                            tabSettings.customLo = Calendar.current.date(byAdding: .day, value: -6, to: Date())
                        }
                        if tabSettings.customHi == nil { tabSettings.customHi = Date() }
                    }
                    tabSettings.toggle(id, on: on)
                }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(id == "today")

            Text(tabLabel(id))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(id == "today" ? .secondary : .primary)

            if id == "today" {
                Text("固定").font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            Spacer()

            if id == "thisWeek" {
                Picker("", selection: $tabSettings.weekStartMonday) {
                    Text("周一").tag(true)
                    Text("周日").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 84)
                .controlSize(.mini)
                .labelsHidden()
            } else if id == "custom" {
                customRangeControl
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .opacity(draggingTab == id ? 0.4 : 1)
        .draggableTab(id != "today", id: id, dragging: $draggingTab)
        .onDrop(of: [.text], delegate: TabDropDelegate(item: id, dragging: $draggingTab) { drag, target in
            tabSettings.reorder(drag, onto: target)
        })
    }

    /// 自定义区间的起止日期选择（设置弹窗内 = 真 NSWindow，DatePicker 稳，无 popover 失焦坑）
    private var customRangeControl: some View {
        HStack(spacing: 4) {
            DatePicker("", selection: Binding(
                get: { tabSettings.customLo ?? Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date() },
                set: { tabSettings.customLo = $0 }
            ), displayedComponents: .date)
            .labelsHidden().datePickerStyle(.field).controlSize(.mini)

            Text("–").font(.system(size: 9)).foregroundStyle(.secondary)

            DatePicker("", selection: Binding(
                get: { tabSettings.customHi ?? Date() },
                set: { tabSettings.customHi = $0 }
            ), displayedComponents: .date)
            .labelsHidden().datePickerStyle(.field).controlSize(.mini)
        }
    }

    private func tabLabel(_ id: String) -> String {
        switch id {
        case "today": return "今日"
        case "thisWeek": return "本周"
        case "last7Days": return "近 7 天"
        case "thisMonth": return "本月"
        case "last30Days": return "近 30 天"
        case "all": return "累计"
        case "custom": return "自定义区间"
        default: return id
        }
    }

}

// MARK: - 时间标签拖拽重排（onDrag/onDrop）

/// 悬停到某行时把正在拖的项重排到该行位置；松手清空拖拽态。today 的重排在 TabSettings.reorder 里被拦。
private struct TabDropDelegate: DropDelegate {
    let item: String
    @Binding var dragging: String?
    let reorder: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != item else { return }
        reorder(d, item)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private extension View {
    /// 仅当 `enabled` 时给行加 onDrag（today 不可拖）。
    @ViewBuilder
    func draggableTab(_ enabled: Bool, id: String, dragging: Binding<String?>) -> some View {
        if enabled {
            onDrag {
                dragging.wrappedValue = id
                return NSItemProvider(object: id as NSString)
            }
        } else {
            self
        }
    }
}

// MARK: - Qoder token 统计开关横幅（CLI / Work 共用）

/// 设置页 qoder 框顶的 token 统计开关横幅（三态）。CLI 与 QoderWork 共用同一个 env gate。
///
/// - `isAnyGatedPresent==false`（CLI / Work 都没用过）→ 整条不出现。
/// - 未开启 → 橙底警告文案 + [一键开启]。
/// - 已开启 → 绿底「✓ 已开启」+ 生效说明 + 撤销（开启后唯一样式）。
/// 详见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md。
private struct QoderUsageBanner: View {
    @ObservedObject var status: QoderUsageStatus

    var body: some View {
        if status.isAnyGatedPresent {
            Group {
                if status.isEnabled {
                    enabledBanner
                } else {
                    notEnabledBanner
                }
            }
            .padding(.trailing, 2)
        }
    }

    // 未开启：警告 + 一键开启
    private var notEnabledBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Qoder CLI / QoderWork 默认不记录本地 token 消耗。需把环境变量 \(status.envName) 从 0 改为 1 开启记录，才能统计。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let err = status.lastError {
                    Text(err).font(.system(size: 9)).foregroundStyle(.red)
                }
                Spacer()
                Button("一键开启") { status.enable() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    // 已开启：绿底 + 生效说明 + 撤销（开启后唯一样式）
    private var enabledBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                Text("已开启 token 统计（CLI 和 QoderWork 都生效）").font(.system(size: 10, weight: .medium))
                Spacer()
                Button("撤销") { status.disable() }.controlSize(.mini).buttonStyle(.link)
            }
            Text("首次开启后 CLI 新开终端 / QoderWork 重启 app 后才能开始记录")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("已写入 \(status.profileDisplayName)：export \(status.envName)=1")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.green.opacity(0.10)))
        .fixedSize(horizontal: false, vertical: true)
    }
}
