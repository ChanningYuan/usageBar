import AppKit
import SwiftUI
import usageBarCore
import usageBarProviders

// MARK: - Hex Color 扩展

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Provider 元信息（icon / displayName / color）查找

struct ProviderMeta {
    let id: String
    let displayName: String
    let brandColor: String
}

enum ProviderMetaLookup {
    static let map: [String: ProviderMeta] = [
        // Claude family
        "claude-code": .init(id: "claude-code", displayName: "Claude Code", brandColor: "#D97757"),
        "cowork": .init(id: "cowork", displayName: "Claude Cowork", brandColor: "#B05730"),
        // Qoder family(Qoder 自家 AI:CLI/Work/IDE,IDE 2026-05-28 接入 SharedClientCache SQLite 直读)
        "qoder-cli": .init(id: "qoder-cli", displayName: "Qoder (CLI)", brandColor: "#10A37F"),
        "qoder-work": .init(id: "qoder-work", displayName: "Qoder (Work)", brandColor: "#0E7A5F"),
        "qoder-ide": .init(id: "qoder-ide", displayName: "Qoder (IDE)", brandColor: "#0E5F7A"),
        // 独立
        "codex": .init(id: "codex", displayName: "Codex (OpenAI)", brandColor: "#10A37F"),
        "wukong": .init(id: "wukong", displayName: "悟空", brandColor: "#1677FF"),
        "workbuddy": .init(id: "workbuddy", displayName: "WorkBuddy", brandColor: "#5B5BD6"),
        "cursor": .init(id: "cursor", displayName: "Cursor", brandColor: "#000000"),
        "openclaw": .init(id: "openclaw", displayName: "OpenClaw", brandColor: "#E8632C"),
        "hermes": .init(id: "hermes", displayName: "Hermes Agent", brandColor: "#7C3AED"),
        "opencode": .init(id: "opencode", displayName: "OpenCode", brandColor: "#F59E0B"),
    ]

    static func meta(for id: String) -> ProviderMeta {
        map[id] ?? ProviderMeta(id: id, displayName: id, brandColor: "#808080")
    }
}

// MARK: - Bundle 资源加载 helper

enum BundleIconLoader {
    /// 资源 bundle 的查找逻辑。**不用 Bundle.module**，因为它找不到资源时直接 fatalError 崩进程。
    /// 这里做 lazy 容错查找：找到就缓存返回，找不到 return nil，让调用者优雅降级。
    /// 已知会触发 Bundle.module fatalError 的场景：App Translocation（未清 quarantine 双击启动）、
    /// install.sh 中途失败留下半残 .app 等边缘情况——同事 macOS 15.5 的 EXC_BREAKPOINT 崩溃就是这个根因。
    private final class BundleFinder {}

    private static let resourceBundle: Bundle? = {
        let bundleName = "usageBar_usageBar"
        let candidates: [URL?] = [
            // 1. 标准 .app 安装路径：Bundle.main/Contents/Resources/usageBar_usageBar.bundle
            Bundle.main.resourceURL?.appendingPathComponent(bundleName + ".bundle"),
            // 2. Bundle.main bundle 同级（命令行 / unbundled）
            Bundle.main.bundleURL.appendingPathComponent(bundleName + ".bundle"),
            // 3. .app 内显式拼 Contents/Resources/
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/" + bundleName + ".bundle"),
            // 4. 通过 BundleFinder 类定位（unit test / 嵌入式场景）
            Bundle(for: BundleFinder.self).resourceURL?.appendingPathComponent(bundleName + ".bundle"),
            Bundle(for: BundleFinder.self).bundleURL.appendingPathComponent(bundleName + ".bundle"),
        ]
        for candidate in candidates {
            if let url = candidate, let bundle = Bundle(url: url) {
                NSLog("[BundleIconLoader] resource bundle 命中: %@", url.path)
                return bundle
            }
        }
        NSLog("[BundleIconLoader] ❌ 未找到 %@.bundle，所有候选路径 miss。Bundle.main.bundleURL=%@",
              bundleName, Bundle.main.bundleURL.path)
        return nil
    }()

    /// 从 bundle 加载 SVG/PNG，返回 NSImage。SwiftUI Image(name:) 不支持直接加载 raw 文件，必须走 NSImage。
    /// 多层 fallback：resource bundle → Bundle.main 顶层 → 显式拼路径。完全找不到 return nil（图标缺失但不崩）。
    static func load(name: String, ext: String) -> NSImage? {
        // 1. 优先用 resource bundle
        if let url = resourceBundle?.url(forResource: name, withExtension: ext) {
            return NSImage(contentsOf: url)
        }
        // 2. Fallback: Bundle.main 顶层（资源直接平铺在 Contents/Resources/ 时）
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return NSImage(contentsOf: url)
        }
        // 3. Fallback: 文件系统级显式拼路径
        if let resURL = Bundle.main.resourceURL {
            let direct = resURL.appendingPathComponent("usageBar_usageBar.bundle/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: direct.path) {
                return NSImage(contentsOf: direct)
            }
        }
        NSLog("[BundleIconLoader] ❌ load(name: %@, ext: %@) 全部 fallback 都 miss", name, ext)
        return nil
    }

    /// 从 bundle 加载原始数据（价目快照 pricing-snapshot.json 用）。同款多层 fallback，缺失 return nil。
    static func loadData(name: String, ext: String) -> Data? {
        if let url = resourceBundle?.url(forResource: name, withExtension: ext),
           let d = try? Data(contentsOf: url) {
            return d
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let d = try? Data(contentsOf: url) {
            return d
        }
        if let resURL = Bundle.main.resourceURL {
            let direct = resURL.appendingPathComponent("usageBar_usageBar.bundle/\(name).\(ext)")
            if let d = try? Data(contentsOf: direct) { return d }
        }
        NSLog("[BundleIconLoader] ❌ loadData(name: %@, ext: %@) 全部 fallback 都 miss", name, ext)
        return nil
    }
}

// MARK: - Provider Icon（每个 provider 一个 22×22 视图）

struct ProviderIcon: View {
    let providerId: String

    @Environment(\.colorScheme) private var colorScheme

    private let size: CGFloat = 22
    private var cornerRadius: CGFloat { size * 0.22 }

    @ViewBuilder
    var body: some View {
        // family 模式优先(claude-* / cowork / qoder-*),fall back 到原 case
        if providerId.hasPrefix("claude-") || providerId == "cowork" {
            // Claude Code / Cowork 沿用各自色 + claude.svg(cowork 用更深的陶土底区分)
            let bg = ProviderMetaLookup.meta(for: providerId).brandColor
            roundedBoxWithBundleImage(bg: bg, name: "claude", ext: "svg")
        } else if providerId.hasPrefix("qoder-") {
            // Qoder 系按子产品分图:
            //   - qoder-work:绿色对话气泡(Q 笑脸)—— QoderWork 官方矢量 icon,抽自 app.asar/out/renderer/icon.svg
            //   - qoder-cli / qoder-ide:Qoder 品牌 logo(黑底+绿 Q+白细节,self-contained)
            // 三者通过 displayName 后缀 + token bar 颜色(brandColor)进一步区分。
            // fallback 到 brandColor 圆角底 + "Qoder" 白字
            let iconName = providerId == "qoder-work" ? "qoderwork" : "qoder"
            if let img = BundleIconLoader.load(name: iconName, ext: "svg") {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                let bg = ProviderMetaLookup.meta(for: providerId).brandColor
                roundedBox(bg: bg) {
                    Text("Qoder")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        } else {
            switch providerId {
            case "codex":
                roundedBoxWithBundleImage(bg: "#10A37F", name: "codex", ext: "svg")
            case "workbuddy":
                // WorkBuddy:官方彩色 app 图标(绿色,自带圆角背景,抽自 WorkBuddy.app)
                if let img = BundleIconLoader.load(name: "workbuddy", ext: "png") {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    Color.clear.frame(width: size, height: size)
                }
            case "cursor":
                // Cursor:官方彩色 app 图标(黑底银灰立体方块,自带圆角背景,抽自 Cursor.app)
                if let img = BundleIconLoader.load(name: "cursor", ext: "png") {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    Color.clear.frame(width: size, height: size)
                }
            case "openclaw":
                // OpenClaw:官方像素龙虾 logo(红橙色,抽自 openclaw 仓库 docs/assets)
                if let img = BundleIconLoader.load(name: "openclaw", ext: "svg") {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    roundedBox(bg: "#E8632C") {
                        Text("OC").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            case "hermes":
                // Hermes Agent:NousResearch 组织 logo(黑底白圈 NOUS,无独立方形 logo 用此)
                if let img = BundleIconLoader.load(name: "hermes", ext: "png") {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    roundedBox(bg: "#7C3AED") {
                        Text("H").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                }
            case "opencode":
                // OpenCode:官方像素风方块 mark(brand 页双变体:浅色黑框/深色白框,黑框在深色主题下会隐形)
                if let img = BundleIconLoader.load(
                    name: colorScheme == .dark ? "opencode-dark" : "opencode", ext: "svg") {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    roundedBox(bg: "#F59E0B") {
                        Text("OC").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            case "wukong":
                // 悟空:无底色,直接显示 PNG(PNG 自己有设计)
                if let img = BundleIconLoader.load(name: "wukong", ext: "png") {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    Color.clear.frame(width: size, height: size)
                }
            default:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: size, height: size)
            }
        }
    }

    /// 圆角方背景 + 内容 overlay
    @ViewBuilder
    private func roundedBox<Content: View>(bg: String, @ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(hex: bg))
            .frame(width: size, height: size)
            .overlay(content())
    }

    /// 圆角方背景 + bundle 资源图（SVG/PNG）
    private func roundedBoxWithBundleImage(bg: String, name: String, ext: String) -> some View {
        roundedBox(bg: bg) {
            if let img = BundleIconLoader.load(name: name, ext: ext) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.62, height: size * 0.62)
            }
        }
    }
}

// MARK: - Root

struct UsageRootView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var settings: ProviderVisibilitySettings = .shared
    @ObservedObject var qoderStatus: QoderUsageStatus = .shared
    @ObservedObject var tabSettings: TabSettings = .shared

    /// GitHub mark(模板图,跟随明暗主题色),给 footer 的"去 GitHub"入口用
    private static let githubIcon: NSImage? = {
        guard let img = BundleIconLoader.load(name: "github", ext: "svg") else { return nil }
        img.isTemplate = true
        return img
    }()

    /// 某个受 gate 的 qoder 产品(cli/work)是否该在它行下挂"未开启"提示。
    /// CLI 与 Work 各自挂一条（同一个 env，点任一跳设置页都能看到是共享开关）。
    private func showsQoderHint(for pid: String) -> Bool {
        guard !qoderStatus.isEnabled, visibleProviderIds.contains(pid) else { return false }
        switch pid {
        case "qoder-cli":  return qoderStatus.isCliPresent
        case "qoder-work": return qoderStatus.isWorkPresent
        default:           return false
        }
    }

    /// 当前要显示的 qoder 未开启提示行条数(0~2),用于算高度。
    private var qoderHintCount: Int {
        (showsQoderHint(for: "qoder-cli") ? 1 : 0) + (showsQoderHint(for: "qoder-work") ? 1 : 0)
    }

    /// 按行数动态算 popover 内容区高度,空状态(0 行)给个最小占位
    /// 26pt 行高 + 5pt 间距,加 16pt 上下 padding。header/footer 各约 28pt。
    private var contentHeight: CGFloat {
        let n = max(displayedProviderIds.count, 1)
        var h = CGFloat(n) * 32 + CGFloat(max(0, n - 1)) * 5 + 16   // 两行行高（名称+细进度条）
        h += CGFloat(qoderHintCount) * 23   // 每条未开启提示行(18) + 间距(5)
        return h
    }

    private var totalHeight: CGFloat {
        contentHeight + 28 + 28 + 2  // header + footer + 2 divider
    }

    var body: some View {
        Group {
            if let pid = viewModel.detailProviderId {
                // drill-in：整个弹层切成该 provider 的详情页（顶部 ‹返回 回列表）
                ProviderDetailView(viewModel: viewModel, providerId: pid)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                    Divider()
                    footer
                }
                .frame(width: 400, height: totalHeight)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onAppear { qoderStatus.refresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 11, weight: .medium))
            Text("usageBar")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            if tabWindows.count <= 1 {
                // 只剩「今日」一个标签：不用 segmented（单段光杆按钮丑）→ 标题 + 幽灵「＋自定义」入口
                Text(windowLabel(tabWindows.first ?? .today))
                    .font(.system(size: 11, weight: .semibold))
                Button(action: {
                    SettingsNavigation.shared.requestFocusTimeTabs()
                    SettingsWindowController.shared.showWindow()
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "plus").font(.system(size: 8))
                        Text("自定义").font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .help("添加时间标签")
            } else {
                Picker("", selection: Binding(
                    get: { tabWindows.contains(viewModel.window) ? viewModel.window : .today },
                    set: { viewModel.changeWindow($0) }
                )) {
                    ForEach(tabWindows, id: \.self) { win in
                        Text(windowLabel(win)).tag(win)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .controlSize(.small)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 时间标签栏（按 TabSettings 动态渲染）

    /// 当前要渲染的 tab 窗口序列（勾选 ∩ 顺序；custom 需区间有效）。逻辑见 `TimeTabs.swift`（详情页共用）。
    private var tabWindows: [TimeWindow] {
        tabSettings.orderedWindows
    }

    private func windowLabel(_ w: TimeWindow) -> String { w.tabLabel }

    /// 当前可见 provider id 列表(按 ProviderRegistry 注册顺序 + Settings 过滤)
    private var visibleProviderIds: [String] {
        settings.visibleProviderIds()
    }

    /// 在「可见」基础上，再按当前周期过滤后**真正要展示**的 provider：
    /// - 一般 provider / Cursor / gate 开的 Qoder：该周期 `token>0` 才显示（没用就隐藏）。
    /// - gate 关的 Qoder（CLI/Work）：装了就显示（`showsQoderHint` = gate 关 + present，不分周期），
    ///   token=0 也保留并挂「去开启」——否则用户永远看不到开启引导。
    private var displayedProviderIds: [String] {
        func token(_ pid: String) -> Int { viewModel.stats.first { $0.provider == pid }?.token ?? 0 }
        let filtered = visibleProviderIds.filter { token($0) > 0 || showsQoderHint(for: $0) }
        // 按当前周期用量降序；token 相同（如多个 Qoder「去开启」0 行）保持原注册顺序（稳定排序）
        return filtered.enumerated()
            .sorted { a, b in
                let ta = token(a.element), tb = token(b.element)
                return ta != tb ? ta > tb : a.offset < b.offset
            }
            .map { $0.element }
    }

    private var content: some View {
        let maxT = viewModel.maxToken
        let visible = visibleProviderIds
        let displayed = displayedProviderIds
        return Group {
            if visible.isEmpty {
                centeredHint("所有 provider 都已在偏好设置中关闭")
            } else if displayed.isEmpty {
                centeredHint(noUsageMessage)
            } else {
                VStack(spacing: 5) {
                    ForEach(displayed, id: \.self) { pid in
                        let stat = viewModel.stats.first { $0.provider == pid } ?? StatRecord(provider: pid, time: viewModel.window.id, token: 0)
                        ProviderRowView(
                            stat: stat,
                            maxToken: maxT,
                            // 门禁由 provider 声明表决定（有 spec 才能 drill-in），
                            // 不再手写白名单——加详情页时漏改这里就是「点不进去」。
                            expandable: ProviderDetailRegistry.isDrillable(pid),
                            onExpand: { viewModel.openDetail(pid) }
                        )
                        if showsQoderHint(for: pid) {
                            qoderHintRow
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// 居中提示（两种空状态共用）
    private func centeredHint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 当前周期无任何用量时的空状态文案（按周期措辞，引导用户去用 AI）
    private var noUsageMessage: String {
        switch viewModel.window {
        case .today:      return "今天还没烧 token —— 快去蹬两下 AI 🚀"
        case .thisWeek:   return "本周还没有用量 —— 去用用 AI 吧 🚀"
        case .last7Days:  return "近 7 天还没有用量 —— 去用用 AI 吧 🚀"
        case .thisMonth:  return "本月还没有用量 —— 去用用 AI 吧 🚀"
        case .last30Days: return "近 30 天还没有用量 —— 去用用 AI 吧 🚀"
        case .all:        return "还没有任何用量 —— 装好就去用 AI 吧 🚀"
        case .custom:     return "这段时间还没有用量 🚀"
        }
    }

    /// Qoder CLI / Work 用过但没开 token 统计 → 弹层在对应行下挂引导行(点「去开启」跳设置页)
    private var qoderHintRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            Text("token 统计未开启")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button {
                SettingsWindowController.shared.showWindow()
            } label: {
                HStack(spacing: 2) {
                    Text("去开启").font(.system(size: 10, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 7))
                }
            }
            .buttonStyle(.link)
            Spacer()
        }
        .padding(.leading, 32)   // 对齐 provider 名(icon 22 + spacing 10)
        .frame(height: 18)
    }

    /// 只算可见 provider 的合计
    private var visibleGrandTotal: Int {
        let ids = Set(visibleProviderIds)
        return viewModel.stats
            .filter { ids.contains($0.provider) }
            .reduce(0) { $0 + $1.token }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("合计 \(formatTokens(visibleGrandTotal))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))   // 统一 11pt medium
                .copyableExact(visibleGrandTotal)

            Spacer()

            statusLabel
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)   // 刷新状态属次要信息，与缓存% 同层次调淡

            Spacer()

            // GitHub 按钮 → 打开仓库(低调常驻入口,想点 Star 的人随时点)
            Button(action: {
                if let url = URL(string: "https://github.com/ChanningYuan/usageBar") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Group {
                    if let img = Self.githubIcon {
                        Image(nsImage: img)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "star")
                    }
                }
                .frame(width: 12, height: 12)
            }
            .buttonStyle(.borderless)
            .help("在 GitHub 上点个 Star ⭐")

            // 齿轮按钮 → Settings 窗口(跟右键菜单 ⌘, 入口等价,popover 内快捷入口)
            Button(action: {
                SettingsWindowController.shared.showWindow()
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("偏好设置 (⌘,)")

            Button(action: {
                Task { await viewModel.refresh() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshing)
            .help("立即刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if viewModel.isRefreshing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("刷新中…")
            }
        } else if viewModel.justRefreshed {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已更新")
                    .foregroundStyle(.green)
            }
            .transition(.opacity)
        } else if let last = viewModel.lastRefreshAt {
            Text("\(last, format: .relative(presentation: .named, unitsStyle: .wide)) 刷新")
        } else {
            Text("尚未刷新")
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Provider 单行

struct ProviderRowView: View {
    let stat: StatRecord
    let maxToken: Int
    /// 可展开（v1 只有 Claude 订阅 / API）→ 悬浮浮现 › 导航箭头 + 行高亮，点击进详情页
    var expandable: Bool = false
    var onExpand: (() -> Void)? = nil
    @State private var hoveringCache = false
    @State private var hoveringRow = false

    private var meta: ProviderMeta { ProviderMetaLookup.meta(for: stat.provider) }
    private var cached: Int { max(0, min(stat.cachedToken, stat.token)) }
    private var nonCached: Int { max(0, stat.token - cached) }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(providerId: stat.provider)
                .frame(width: 22, height: 22)

            // 中间：名称(+缓存命中率) + 名称下方的细进度条（占满中间宽度）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(meta.displayName)
                        .font(.system(size: 11, weight: .medium))   // 统一 11pt medium（偏细）
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if cached > 0 {
                        // 缓存命中率（次要）；hover 它 → 弹绝对值拆分气泡（缓存信息聚在一处）
                        Text(String(format: "%.1f%% 缓存命中", Double(cached) / Double(stat.token) * 100))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .contentShape(Rectangle())
                            .onHover { hoveringCache = $0 }
                            .overlay(alignment: .top) {
                                if hoveringCache { cacheBubble.offset(y: -28).allowsHitTesting(false) }
                            }
                    }
                }
                TokenBar(token: stat.token, maxToken: maxToken, brandColor: meta.brandColor)
                    .frame(height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧：数字（统一 11pt medium；用整行高 frame 让它按「整个 provider 容器」垂直居中；虚线贴紧）
            Text(formatTokens(stat.token))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(stat.token > 0 ? .primary : .secondary)
                .overlay(alignment: .bottom) {
                    if stat.token > 0 { DashedUnderline().frame(height: 1).offset(y: 1) }
                }
                .frame(width: 66, height: 32, alignment: .trailing)
                .copyableExact(stat.token)

            // 悬浮才浮现的 › 导航箭头（drill-in「点进详情」指示，不常驻）
            if expandable && hoveringRow {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(expandable && hoveringRow ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if expandable { withAnimation(.easeInOut(duration: 0.12)) { hoveringRow = hovering } }
        }
        .onTapGesture { if expandable { onExpand?() } }
    }

    // 悬浮气泡：缓存/非缓存绝对值（白卡片样式，与数字/合计的复制浮层一致）
    private var cacheBubble: some View {
        HStack(spacing: 10) {
            bubbleSeg(label: "缓存", value: cached)
            Divider().frame(height: 12)
            bubbleSeg(label: "非缓存", value: nonCached)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        .fixedSize()
    }

    private func bubbleSeg(label: String, value: Int) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(fmtExact(value)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func fmtExact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func formatTokens(_ n: Int) -> String {
        if n == 0 { return "—" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - 双色 token 进度条（浅=缓存命中在左，深=非缓存在右）+ 悬浮拆分气泡

private struct TokenBar: View {
    let token: Int
    let maxToken: Int
    let brandColor: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let hasData = token > 0 && maxToken > 0
            let totalW = hasData ? max(2, w * CGFloat(token) / CGFloat(maxToken)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                if hasData {
                    Capsule().fill(Color(hex: brandColor))   // 单色：纯表用量对比
                        .frame(width: totalW)
                }
            }
        }
    }
}

// MARK: - 数字「点击复制 / 悬浮看精确值」修饰器

/// 把显示缩写数字（74.9M）的 Text 变成：悬浮即显精确值（千分位）+「点击复制」提示行；
/// 点击复制 **raw 整数**（无千分位、无单位）到剪贴板，并在上方短暂浮「已复制 ✓」。
/// value <= 0 时无任何附加行为（零用量行不可点 / 不弹 tooltip）。
/// 虚线下划线 —— 行尾数字「可点击复制」的视觉提示（配合 CopyableExact 的 hover+点击）
private struct DashedUnderline: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: g.size.width, y: 0.5))
            }
            .stroke(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }
}

private struct CopyableExact: ViewModifier {
    let value: Int
    @State private var hovering = false
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hovering = $0 && value > 0 }       // 自定义 hover：即时，不走原生 tooltip 的慢延迟
            .onTapGesture {
                guard value > 0 else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(value), forType: .string)
                copied = true
                hovering = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
            }
            .overlay(alignment: .top) { floatTip.offset(y: -26).allowsHitTesting(false) }
    }

    @ViewBuilder private var floatTip: some View {
        if copied {
            Text("已复制 ✓")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.green))
                .fixedSize()
        } else if hovering {
            VStack(spacing: 1) {
                Text(value.formatted())
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("点击复制")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            .fixedSize()
        }
    }
}

private extension View {
    func copyableExact(_ value: Int) -> some View { modifier(CopyableExact(value: value)) }
}
