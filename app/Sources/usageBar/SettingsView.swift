import AppKit
import SwiftUI
import usageBarCore
import usageBarProviders

/// Settings 面板(右键菜单 → 偏好设置...)
///
/// 形态:family 用虚线圆角框包起来,标题压在虚线边上(类似 HTML fieldset);
/// 独立 provider(Codex/悟空)不框,直接平铺。无父级 Toggle — 用户要"关 family 整组"
/// 自己把子项各自关掉即可(UI 视觉用虚线框提示同组关联)。
struct SettingsView: View {
    @ObservedObject var settings: ProviderVisibilitySettings
    @ObservedObject private var qoderStatus: QoderUsageStatus = .shared
    @ObservedObject private var tabSettings: TabSettings = .shared

    private let familyDisplayName: [String: String] = [
        "claude": "Claude",  // 含 Claude Code(订阅/API) + Cowork,故组名用 "Claude"
    ]

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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeTabsSection
                    ForEach(groupedSections, id: \.id) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - 时间标签（popover tab 栏配置）

    /// 虚线 fieldset 风格分组：勾选哪些周期作为 popover tab + 拖拽排序 + 本周周起始 + 自定义区间
    private var timeTabsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("勾选显示在弹层顶部的时间标签 · 拖动排序 · 最多 \(TabSettings.maxTabs) 个")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(tabSettings.order, id: \.self) { id in
                    timeTabRow(id)
                }
                .onMove { tabSettings.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(tabSettings.order.count) * 28)

            let cnt = tabSettings.checked.count
            Text("已选 \(cnt)/\(TabSettings.maxTabs)" + (cnt >= TabSettings.maxTabs ? " · 已满，取消一个再加" : ""))
                .font(.system(size: 9))
                .foregroundStyle(cnt >= TabSettings.maxTabs ? .orange : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .overlay(alignment: .topLeading) {
            Text("时间标签")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .background(Color(nsColor: .windowBackgroundColor))
                .offset(x: 12, y: -7)
        }
    }

    /// 一行候选：勾选框 + 名称 +（本周周起始 / 自定义区间编辑）；today 锁定。
    @ViewBuilder
    private func timeTabRow(_ id: String) -> some View {
        HStack(spacing: 8) {
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
        .frame(height: 24)
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

    // MARK: - 数据分组

    /// 一个"区块":要么是 family(虚线框 + 多子项),要么是 standalone(单 toggle 平铺)
    private struct SettingsSection: Identifiable {
        let id: String
        let title: String
        let family: String?
        let providers: [any UsageProvider]
    }

    private var groupedSections: [SettingsSection] {
        let all = ProviderRegistry.all
        var result: [SettingsSection] = []
        var seenFamilies: Set<String> = []

        for p in all {
            if let fam = p.family {
                if seenFamilies.contains(fam) { continue }
                seenFamilies.insert(fam)
                let famProviders = all.filter { $0.family == fam }
                result.append(SettingsSection(
                    id: "fam:\(fam)",
                    title: familyDisplayName[fam] ?? fam,
                    family: fam,
                    providers: famProviders
                ))
            } else {
                result.append(SettingsSection(
                    id: "prov:\(p.id)",
                    title: p.displayName,
                    family: nil,
                    providers: [p]
                ))
            }
        }
        return result
    }

    // MARK: - Section View

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        if section.family != nil {
            familyBox(title: section.title, family: section.family, providers: section.providers)
        } else if let provider = section.providers.first {
            standaloneRow(provider: provider)
        }
    }

    /// family 块:虚线圆角框 + 压边标题
    private func familyBox(title: String, family: String?, providers: [any UsageProvider]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // qoder 框顶挂一条共享 token 统计开关横幅（CLI/Work 共用一个 env gate）。
            // 按 presence 判定（有会话即出现），不挂在"行可见"上 —— 存量用户即使 Work 行被关着，
            // 打开设置页照样能看到"去开启"。IDE 不受 gate，不在此横幅范围。
            if family == "qoder" {
                QoderUsageBanner(status: qoderStatus)
            }
            ForEach(providers, id: \.id) { p in
                providerToggleRow(p)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .overlay(alignment: .topLeading) {
            // 压在虚线边上的组名标题(背景色覆盖虚线达到 fieldset 视觉)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .background(Color(nsColor: .windowBackgroundColor))
                .offset(x: 12, y: -7)
        }
    }

    /// 单个 provider 的 Toggle 行(虚线框内 / 独立平铺通用)
    private func providerToggleRow(_ p: any UsageProvider) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.isProviderToggleOn(p.id) },
                set: { settings.setProvider(p.id, enabled: $0) }
            )) {
                Text(p.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color(hex: "#007AFF"))  // 开启态用系统蓝,明暗主题都清晰
            Spacer()
        }
    }

    /// 独立 provider:单行 Toggle(Codex / 悟空 / WorkBuddy / Cursor)
    /// 字号/weight 跟虚线框内子项完全一致(size 12 regular),只是水平 padding 跟框内对齐
    private func standaloneRow(provider: any UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { settings.isProviderToggleOn(provider.id) },
                    set: { settings.setProvider(provider.id, enabled: $0) }
                )) {
                    Text(provider.displayName)
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color(hex: "#007AFF"))  // 开启态用系统蓝,明暗主题都清晰
                Spacer()
            }

            // Cursor 专属:隐私提示(它是唯一联网的 provider)
            if provider.id == "cursor" {
                Text("Cursor 真实用量只在服务端，需联网获取：勾选后每次刷新会读取本机 Cursor 登录凭证并请求 cursor.com。不想联网就取消勾选。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
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
