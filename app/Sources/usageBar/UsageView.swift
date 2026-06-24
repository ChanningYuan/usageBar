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
        "claude-sub": .init(id: "claude-sub", displayName: "Claude Code (订阅)", brandColor: "#D97757"),
        "claude-api": .init(id: "claude-api", displayName: "Claude Code (API)", brandColor: "#6F4A8A"),
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
}

// MARK: - Provider Icon（每个 provider 一个 22×22 视图）

struct ProviderIcon: View {
    let providerId: String

    private let size: CGFloat = 22
    private var cornerRadius: CGFloat { size * 0.22 }

    @ViewBuilder
    var body: some View {
        // family 模式优先(claude-* / cowork / qoder-*),fall back 到原 case
        if providerId.hasPrefix("claude-") || providerId == "cowork" {
            // Claude sub/api/cowork 沿用各自色 + claude.svg(cowork 用更深的陶土底区分订阅版)
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
    @ObservedObject var qoderStatus: QoderCliUsageStatus = .shared

    /// GitHub mark(模板图,跟随明暗主题色),给 footer 的"去 GitHub"入口用
    private static let githubIcon: NSImage? = {
        guard let img = BundleIconLoader.load(name: "github", ext: "svg") else { return nil }
        img.isTemplate = true
        return img
    }()

    /// qodercli 装了但没开 token 统计 → 弹层挂一条引导行
    private var showsQoderHint: Bool {
        visibleProviderIds.contains("qoder-cli") && qoderStatus.isPresent && !qoderStatus.isEnabled
    }

    /// 按行数动态算 popover 内容区高度,空状态(0 行)给个最小占位
    /// 26pt 行高 + 5pt 间距,加 16pt 上下 padding。header/footer 各约 28pt。
    private var contentHeight: CGFloat {
        let n = max(visibleProviderIds.count, 1)
        var h = CGFloat(n) * 26 + CGFloat(max(0, n - 1)) * 5 + 16
        if showsQoderHint { h += 23 }   // qodercli 未开启提示行(18) + 间距(5)
        return h
    }

    private var totalHeight: CGFloat {
        contentHeight + 28 + 28 + 2  // header + footer + 2 divider
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 440, height: totalHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { qoderStatus.refresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .semibold))
            Text("usageBar")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Picker("", selection: Binding(
                get: { viewModel.window },
                set: { viewModel.changeWindow($0) }
            )) {
                Text("今日").tag(TimeWindow.today)
                Text("7天").tag(TimeWindow.last7Days)
                Text("30天").tag(TimeWindow.last30Days)
                Text("累计").tag(TimeWindow.all)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 当前可见 provider id 列表(按 ProviderRegistry 注册顺序 + Settings 过滤)
    private var visibleProviderIds: [String] {
        settings.visibleProviderIds()
    }

    private var content: some View {
        let max = viewModel.maxToken
        let ids = visibleProviderIds
        return Group {
            if ids.isEmpty {
                VStack {
                    Spacer()
                    Text("所有 provider 都已在偏好设置中关闭")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 5) {
                    ForEach(ids, id: \.self) { pid in
                        let stat = viewModel.stats.first { $0.provider == pid } ?? StatRecord(provider: pid, time: viewModel.window.id, token: 0)
                        ProviderRowView(stat: stat, maxToken: max)
                        if pid == "qoder-cli" && showsQoderHint {
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

    /// qodercli 装了但没开 token 统计 → 弹层引导行(点「去开启」跳设置页并高亮横幅)
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
                .font(.system(size: 11, weight: .semibold, design: .monospaced))

            Spacer()

            statusLabel
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

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

    private var meta: ProviderMeta {
        ProviderMetaLookup.meta(for: stat.provider)
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(providerId: stat.provider)
                .frame(width: 22, height: 22)

            Text(meta.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 110, alignment: .leading)

            tokenBar
                .frame(height: 7)

            Text(formatTokens(stat.token))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(stat.token > 0 ? .primary : .secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: 26)
    }

    private var tokenBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))

                if stat.token > 0 && maxToken > 0 {
                    Capsule()
                        .fill(Color(hex: meta.brandColor))
                        .frame(width: max(2, geo.size.width * CGFloat(stat.token) / CGFloat(maxToken)))
                }
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n == 0 { return "—" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
