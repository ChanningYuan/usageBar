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

    /// 置 true 表示"打开设置后应展开并滚到账号额度段"（从额度「去授权/去开启」入口跳来）。
    @Published var pendingFocusQuota = false
    func requestFocusQuota() { pendingFocusQuota = true }
}

/// Settings 面板(右键菜单 → 偏好设置...)
///
/// 形态:family 用虚线圆角框包起来,标题压在虚线边上(类似 HTML fieldset);
/// 独立 provider(Codex 等)不框,直接平铺。无父级 Toggle — 用户要"关 family 整组"
/// 自己把子项各自关掉即可(UI 视觉用虚线框提示同组关联)。
struct SettingsView: View {
    @ObservedObject var settings: ProviderVisibilitySettings
    @ObservedObject private var qoderStatus: QoderUsageStatus = .shared
    @ObservedObject private var tabSettings: TabSettings = .shared
    @ObservedObject private var themeSettings: ThemeSettings = .shared
    @ObservedObject private var launchAtLogin: LaunchAtLoginSettings = .shared
    @ObservedObject private var refreshSettings: RefreshIntervalSettings = .shared
    @ObservedObject private var nav = SettingsNavigation.shared
    @ObservedObject private var quotaSettings: RateLimitSettings = .shared
    @ObservedObject private var quotaStore: RateLimitStore = .shared
    @State private var draggingTab: String?
    @State private var dataSourceExpanded = true
    @State private var quotaExpanded = true
    @State private var tabsExpanded = true
    /// 正在展示引导 sheet 的逻辑开关（claude-code / qoder / qwen-work）；nil = 不展示
    @State private var guideFor: String?
    @ObservedObject private var qwenWeb = QwenWorkWebSessionStatus.shared
    @State private var showQwenPaste = false
    @State private var qwenPasteText = ""
    @State private var qwenPasteError: String?
    /// 价目表新鲜度（打开设置时取一次，避免每次重绘都去读磁盘）
    @State private var pricingFreshness: RemotePricing.Freshness?

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
                        generalSection
                        Divider()
                        dataSourceSection
                        Divider()
                        quotaSection.id("quota")
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
                .onChange(of: nav.pendingFocusQuota) { _, focus in
                    if focus { focusQuota(proxy) }
                }
                .onAppear {
                    // 窗口首次创建：SettingsView 才 appear，此时消费待聚焦请求
                    if nav.pendingFocusTimeTabs { focusTimeTabs(proxy) }
                    if nav.pendingFocusQuota { focusQuota(proxy) }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            qoderStatus.refresh()
            launchAtLogin.refresh()   // 用户可能在 系统设置→登录项 里改过，回读真实状态
            pricingFreshness = RemotePricing.shared.freshness()
        }
        .sheet(isPresented: Binding(get: { guideFor != nil }, set: { if !$0 { guideFor = nil } })) {
            if let id = guideFor {
                RateLimitGuideSheet(
                    logicalId: id,
                    initialSource: quotaSettings.dataSource(for: id),
                    onConfirm: { source in confirmGuide(id, source: source) },
                    onCancel: { guideFor = nil }
                )
            }
        }
    }

    /// 引导 sheet 确认：Claude 落数据源 +（statusline 时）注入脚本；各来源都开启开关并立即采一次。
    private func confirmGuide(_ id: String, source: String) {
        if id == "claude-code" {
            quotaSettings.setDataSource(for: "claude-code", source)
            if source == "statusline" { _ = StatuslineConfigurator.configure() }
            else { StatuslineConfigurator.deconfigure() }   // 换到别的源就撤掉注入，别留脏
        }
        quotaSettings.markConfigured(id)   // 记住已配置 → 下次开启不再弹引导
        quotaSettings.setEnabled(id, true)
        Task { await RateLimitCoordinator.refreshOne(id) }
        guideFor = nil
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

    /// 额度「去授权/去开启」入口触发：展开账号额度段并滚动到它，然后复位信号。
    private func focusQuota(_ proxy: ScrollViewProxy) {
        quotaExpanded = true
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo("quota", anchor: .top) }
        }
        nav.pendingFocusQuota = false
    }

    // MARK: - 折叠段通用

    private var visibleProviderCount: Int {
        ProviderRegistry.all.filter { settings.isProviderToggleOn($0.id) }.count
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

    // MARK: - 通用（开机自启 / 外观主题 / 刷新频率）

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("通用")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            // 开机自启：真值在系统登录项登记表，开关直接 register/unregister
            HStack(spacing: 10) {
                Text("开机自启")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color(hex: "#007AFF"))
                .disabled(!launchAtLogin.isAvailable)
            }
            .frame(height: 22)
            .padding(.leading, 2)

            // 外观主题：深色 / 浅色 / 跟随系统（segmented，实时生效）
            HStack(spacing: 10) {
                Text("外观主题")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("", selection: $themeSettings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 216)
            }
            .frame(height: 22)
            .padding(.leading, 2)

            // 自动刷新频率：1–15 分钟滑轨，默认 10；拖动即生效（定时器按新间隔重建）
            HStack(spacing: 10) {
                Text("自动刷新频率")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Slider(
                    value: Binding(
                        get: { Double(refreshSettings.minutes) },
                        set: { refreshSettings.minutes = Int($0.rounded()) }
                    ),
                    in: Double(RefreshIntervalSettings.range.lowerBound)...Double(RefreshIntervalSettings.range.upperBound),
                    step: 1
                )
                .controlSize(.small)
                .frame(width: 150)
                Text("\(refreshSettings.minutes) 分钟/次")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)   // 定宽，1→15 位数变化不抖动
            }
            .frame(height: 22)
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
            pricingNotice   // 价目表过期提示：折叠与否都要能看见
            if dataSourceExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ProviderRegistry.all, id: \.id) { p in
                        providerRow(p)
                        // gate 横幅**按产品各挂各的**（v0.3.33）：Qoder CLI 与千问办公是两个独立的
                        // 环境变量、两个独立的开关状态，共用一条横幅时用户无法判断"到底谁没开"。
                        // 一键开启仍是同时写两行（共用标记块），只是展示分开。
                        if p.id == "qoder-cli" || p.id == "qwen-work" {
                            QoderUsageBanner(status: qoderStatus, product: p.id)
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

    /// 价目表过期提示（加固③）：拉取失败会静默退化成「表还在、但停更了」——新模型没价、老价格漂移，
    /// 用户完全无感。这里把它显性化。token 统计不受影响，只有 ≈$ 金额会偏旧。
    @ViewBuilder private var pricingNotice: some View {
        if let f = pricingFreshness, f.isStale {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "#D97706"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pricingNoticeTitle(f))
                        .font(.system(size: 10, weight: .semibold))
                    Text("金额是按官方 API 价折算的「等效花费」，价目表每天从 usagebar.cn 更新一次。长期不更新，多半是网络或公司安全软件拦了 usageBar 的请求——token 统计不受影响，只有 ≈$ 金额会偏旧。")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#D97706").opacity(0.09)))
        }
    }

    private func pricingNoticeTitle(_ f: RemotePricing.Freshness) -> String {
        if let updated = f.lastUpdated {
            let days = max(1, Int(Date().timeIntervalSince(updated) / 86400))
            return "价格表已 \(days) 天未更新"
        }
        return f.usingSnapshot
            ? "正在用安装包内置的价格表（从未成功拉到线上表）"
            : "还没拉到价格表"
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

    // MARK: - 账号额度（监测开关折叠段，v0.3.24）

    /// Codex 默认开（纯本地）；Claude / Qoder / 千问办公默认关（联网 + 读钥匙串）。
    /// 每行下挂说明——尤其 Claude 那条必须预告「会弹钥匙串授权框」，否则用户被突然弹框吓到会点拒绝。
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("账号额度与积分", count: "已开启 \(quotaSettings.enabled.count) 个", expanded: quotaExpanded) {
                quotaExpanded.toggle()
            }
            if quotaExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.quotaRows, id: \.id) { row in
                        quotaRow(id: row.id, iconProvider: row.icon, name: row.name, desc: row.desc)
                    }
                }
                .padding(.leading, 2)
            }
        }
    }

    private struct QuotaRowSpec { let id: String; let icon: String; let name: String; let desc: String }
    private static let quotaRows: [QuotaRowSpec] = [
        .init(id: "codex", icon: "codex", name: "Codex",
              desc: "通过本机 Codex CLI 查询官方额度接口（凭据由 Codex 自己管理，不读钥匙串、不弹授权框）。离线时显示上次数据。"),
        .init(id: "claude-code", icon: "claude-code", name: "Claude Code",
              desc: "开启后随每次刷新向 api.anthropic.com 查询。首次会弹一次系统钥匙串授权框（读取 Claude Code 自己保存的登录凭证），选「始终允许」后不再弹。"),
        .init(id: "qoder", icon: "qoder-cli", name: "Qoder",
              desc: "读取本机 Qoder 登录凭证并请求 qoder.com（首次弹一次钥匙串授权框）。CLI 与 IDE 登录同一账号时共用一份额度；登录了不同账号时各行显示各自账号的额度。"),
        .init(id: "qwen-work", icon: "qwen-work", name: "千问办公额度与积分",
              desc: "读取本机千问办公登录凭证，查每日 / 周期 / 长期积分的已用与额度（主列表三颗药丸、详情页额度模块）。今日已用与按会话积分只有网页登录能查到，见下面的「精确模式」。"),
        .init(id: "cursor", icon: "cursor", name: "Cursor",
              desc: "读取本机 Cursor 登录凭证并请求 cursor.com。与「数据源 → Cursor」用同一份凭证。"),
        .init(id: "workbuddy", icon: "workbuddy", name: "WorkBuddy",
              desc: "读本机明文登录文件（零钥匙串授权）并请求 codebuddy.cn，拿信用点余额。"),
    ]

    private func quotaRow(id: String, iconProvider: String, name: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ProviderIcon(providerId: iconProvider)
                    .frame(width: 22, height: 22)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                // 开启后外显：选了哪个数据源 + 授权/连接状态点（绿=有数据 / 橙=授权失败 / 灰=加载中）
                if let chip = quotaChip(id: id) {
                    HStack(spacing: 3) {
                        Circle().fill(chip.dot).frame(width: 5, height: 5)
                        Text(chip.text).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                // 千问办公真掉登录（余额接口也 401）：操作点紧跟 chip（spec 0910 §3.2 C）
                if id == "qwen-work", quotaStore.snapshot(for: "qwen-work")?.error == .credentialUnavailable {
                    Button("打开千问办公 ›") { Self.openQwenWorkApp() }
                        .buttonStyle(.plain)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color(hex: "#007AFF"))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { quotaSettings.isEnabled(id) },
                    set: { on in
                        // Claude / Qoder / 千问办公首次开启弹引导 sheet（选数据源 / 预告钥匙串授权）；
                        // 已配置过的（曾确认过一次）直接开，不重弹——复用上次数据源，避免"关了再开又弹"的怪感。
                        if on, ["claude-code", "qoder", "qwen-work"].contains(id),
                           !quotaSettings.isConfigured(id) {
                            guideFor = id
                            return   // 先不开，等 sheet 确认；toggle 视觉回弹到关
                        }
                        guard quotaSettings.setEnabled(id, on) else { return }
                        if on {
                            Task { await RateLimitCoordinator.refreshOne(id) }   // 立即采一次，免得干等 10 分钟
                        } else {
                            if id == "claude-code" { StatuslineConfigurator.deconfigure() }  // 关 Claude 时撤 statusline 注入
                            RateLimitCoordinator.clear(id)                        // 关掉即清快照
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color(hex: "#007AFF"))
            }
            Text(desc)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 32)
            // 已配置过的（Claude/Qoder/千问办公）显示操作区；Claude 额外可切换数据源。
            if quotaSettings.isConfigured(id) {
                HStack(spacing: 12) {
                    if id == "claude-code" {
                        Button("切换数据源") { guideFor = "claude-code" }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(hex: "#007AFF"))
                    }
                    Button("重置授权") { RateLimitCoordinator.revoke(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: "#D97706"))
                    Spacer()
                }
                .padding(.leading, 32)
            }
            // 千问办公：网页令牌线的子行（精确模式开关 + chip + 操作点），v0.3.38
            if id == "qwen-work", quotaSettings.isEnabled("qwen-work") {
                qwenWorkPreciseRows
            }
        }
    }

    /// 设置行状态标签：数据源 + 连接状态点。
    /// 千问办公也算——它有 `/user/balance` 这个真实的「当前状态」数据源（0804 起）。
    private func quotaChip(id: String) -> (text: String, dot: Color)? {
        guard ["claude-code", "qoder", "qwen-work"].contains(id),
              quotaSettings.isEnabled(id) else { return nil }
        let pid = id == "qoder" ? "qoder-cli" : id
        let snap = quotaStore.snapshot(for: pid)
        let dot: Color
        if let snap {
            if !snap.windows.isEmpty { dot = Color(hex: "#1F8A54") }                       // 有数据 = 绿
            else if snap.error == .credentialUnavailable || snap.error == .authDenied
                        || snap.error == .notLoggedIn { dot = Color(hex: "#D97706") }        // 授权失败 / 未登录 = 橙
            else { dot = .secondary }                              // noQuotaData / quotaUnavailable / 加载中 = 灰
        } else { dot = .secondary }
        let text: String
        switch id {
        case "claude-code":
            switch quotaSettings.dataSource(for: "claude-code") {
            case "cli": text = "/usage"
            case "oauth": text = "联网 API"
            default: text = "statusline"
            }
        case "qwen-work":
            // 主行 chip 只表示桌面令牌这条线；网页令牌线的状态在子行（spec 0910 §3.2 C）
            text = snap?.error == .credentialUnavailable ? "凭证已失效" : "已连接"
        default: text = "联网 API"
        }
        return (text, dot)
    }

    // MARK: - 千问办公 · 精确模式子行（网页令牌线，v0.3.38）

    private var qwenWorkPreciseRows: some View {
        let chip = qwenWeb.chip
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("精确模式 · 读取 Chrome 里的网页登录")
                    .font(.system(size: 10.5, weight: .medium))
                HStack(spacing: 3) {
                    Circle().fill(qwenChipColor(chip.tone)).frame(width: 5, height: 5)
                    Text(chip.text).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                if let action = chip.action {
                    Button(action.title) { performQwenAction(action.kind) }
                        .buttonStyle(.plain)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color(hex: "#007AFF"))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { quotaSettings.qwenWorkPreciseMode },
                    set: { on in RateLimitCoordinator.setQwenWorkPreciseMode(on) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color(hex: "#007AFF"))
            }
            Text("今日已用与按会话积分只有网页登录能查到。开启后读取 Chrome 里 qwenwork.cn 的登录（首次弹一次「Chrome Safe Storage」钥匙串授权，选「始终允许」后不再弹），只取 token 一条，缓存进 usageBar 自己的钥匙串条目；授权被拒后 6 小时内不再自动尝试。网页登录 48 小时一换，过期后在 Chrome 打开一次用量明细页即可恢复。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("手动粘贴 Cookie / cURL ›") { qwenPasteError = nil; showQwenPaste = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(hex: "#007AFF"))
                // 精确模式关着时「打开用量明细页」没意义（没人去读 cookie），只留手动粘贴（设计稿 S1）
                if quotaSettings.qwenWorkPreciseMode {
                    Button("打开用量明细页 ›") { NSWorkspace.shared.open(QwenWorkBillingStore.usagePageURL) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: "#007AFF"))
                }
                Spacer()
            }
        }
        .padding(.leading, 32)
        .padding(.top, 4)
        .sheet(isPresented: $showQwenPaste) { qwenPasteSheet }
    }

    private func qwenChipColor(_ tone: QwenWorkWebSessionStatus.Chip.Tone) -> Color {
        switch tone {
        case .green: return Color(hex: "#1F8A54")
        case .gray: return .secondary
        case .orange: return Color(hex: "#D97706")
        }
    }

    private func performQwenAction(_ kind: QwenWorkWebSessionStatus.Chip.Action) {
        switch kind {
        case .openUsagePage: NSWorkspace.shared.open(QwenWorkBillingStore.usagePageURL)
        case .reauthorize: RateLimitCoordinator.retryQwenWorkChromeAuthorization()
        case .pasteManually: qwenPasteError = nil; showQwenPaste = true
        }
    }

    /// 唤起千问办公 app 让用户重新登录；没装就退到网页版。
    private static func openQwenWorkApp() {
        let url = URL(fileURLWithPath: "/Applications/QwenWorkCN.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(QwenWorkBillingStore.usagePageURL)
        }
    }

    private var qwenPasteSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("粘贴千问办公的网页登录").font(.system(size: 13, weight: .semibold))
            Text("在 Chrome 打开 qwenwork.cn 的「用量明细」页 → 开发者工具 Network → 任一 /user/ 请求右键「Copy as cURL」，整段粘贴到下面；也可以只粘贴 Cookie 头或 token=… 那一段。usageBar 只保留 token 一项，存进自己的钥匙串条目，不上传。网页登录 48 小时一换，过期后再粘一次或在 Chrome 打开一次用量明细页。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $qwenPasteText)
                .font(.system(size: 10, design: .monospaced))
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            if let err = qwenPasteError {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { qwenPasteText = ""; showQwenPaste = false }
                Button("保存") { saveQwenPaste() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func saveQwenPaste() {
        let text = qwenPasteText
        Task {
            let exp = await QwenWorkBillingStore.shared.setManualWebToken(text)
            await MainActor.run {
                if exp != nil {
                    qwenPasteText = ""
                    qwenPasteError = nil
                    showQwenPaste = false
                    quotaSettings.setQwenWorkPreciseMode(true)
                } else {
                    qwenPasteError = "没找到有效的 token（或已过期）。请确认粘贴的是 qwenwork.cn 的 cURL / Cookie 头。"
                }
            }
            if exp != nil { await RateLimitCoordinator.refreshOne("qwen-work") }
        }
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
        case "yesterday": return "昨日"
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

// MARK: - Qoder SDK token 统计开关横幅（统一管理 CLI / Work / 千问办公）

/// 一键同时管理 Qoder 的 `QODER_` gate 与千问办公的 `QODERCN_` gate。
///
/// - `isAnyGatedPresent==false`（三个产品都没用过）→ 整条不出现。
/// - 未开启 → 橙底警告文案 + [一键开启]。
/// - 已开启 → 绿底「✓ 已开启」+ 生效说明 + 撤销（开启后唯一样式）。
/// 详见 docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md。
private struct QoderUsageBanner: View {
    @ObservedObject var status: QoderUsageStatus
    /// 这条横幅属于哪个产品："qoder-cli" 或 "qwen-work"。
    ///
    /// v0.3.33 拆开：Qoder CLI 看 `QODER_EXPOSE_TOKEN_USAGE`、千问办公看 `QODERCN_EXPOSE_TOKEN_USAGE`，
    /// 是**两个独立变量、两个独立状态**。此前共用一条横幅挂在最后一个受控产品之后，
    /// 用户看到「未开启」也不知道是哪个没开，而且横幅离对应的数据源行很远。
    let product: String

    /// 该产品是否装过（没用过就不打扰）
    private var isPresent: Bool {
        product == "qwen-work" ? status.isQwenWorkPresent : status.isCliPresent
    }

    /// 该产品自己的 gate 是否已开
    private var isOn: Bool {
        product == "qwen-work" ? status.isQwenWorkEnabled : status.isQoderEnabled
    }

    private var envName: String {
        product == "qwen-work" ? QoderUsageEnvGate.qwenWorkEnvName : QoderUsageEnvGate.qoderEnvName
    }

    private var productName: String {
        product == "qwen-work" ? "千问办公" : "Qoder CLI"
    }

    /// 开启后要做什么才生效：CLI 是新开终端，GUI app 要重启自己。
    private var takeEffectHint: String {
        product == "qwen-work" ? "重启千问办公后开始记录" : "新开终端后开始记录"
    }

    var body: some View {
        if isPresent {
            Group {
                if isOn { enabledBanner } else { notEnabledBanner }
            }
            .padding(.leading, 32)   // 与 provider 名对齐（icon 22 + spacing 10）
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
                Text("需开启 \(envName) 才能统计到 token，只统计开启后的新请求。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let err = status.lastError {
                    Text(err).font(.system(size: 9)).foregroundStyle(.red)
                }
                Spacer()
                // 一键开启仍是**一次写两行**（两个产品共用同一个 profile 标记块，
                // 分开写会互相覆盖）。这里只是入口分散到各自行下，行为不变。
                // 只开自己这一个产品的 gate（另一个产品的开关状态不受影响）
                Button("开启") { status.enable(product: product) }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    // 已开启：绿底 + 生效说明 + 撤销
    private var enabledBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                Text("已开启 token 统计").font(.system(size: 10, weight: .medium))
                Spacer()
                // 只撤销自己这一个；另一个产品若已开，保持不变
                Button("撤销") { status.disable(product: product) }.controlSize(.mini).buttonStyle(.link)
            }
            Text("\(takeEffectHint)；已写入 \(status.profileDisplayName)：export \(envName)=1")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.green.opacity(0.10)))
        .fixedSize(horizontal: false, vertical: true)
    }
}
