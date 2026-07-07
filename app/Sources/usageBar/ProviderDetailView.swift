import SwiftUI
import usageBarCore
import usageBarProviders

/// Provider 详情页（drill-in）——图标格版：Hero + 缓存命中环 + Token 2×2 图标格
/// + 分模型（命中率 pill + 花费）+ 分会话（排序 + 展开全部/收起）。
/// v1 只给 Claude 订阅 / API 用（懒加载数据来自 `ClaudeDetailScanner`）。
///
/// 色板 / 字号严格对齐设计稿 `展开明细-分镜.pen`（YMWLk 浅 / MvCZv 深）：
/// 强调色浅 #C85A2B / 深 #E8794F，文字三级 text/text2/text3，卡片 lCard/dCard 等。
struct ProviderDetailView: View {
    @ObservedObject var viewModel: UsageViewModel
    let providerId: String

    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var tabSettings = TabSettings.shared
    @State private var sortByTime = false
    @State private var showAllSessions = false
    /// 详情内容实测高度（驱动弹层自适应，避免内容矮时底部留白）。
    @State private var bodyHeight: CGFloat = 0
    /// 内容区高度上限：超过则封顶滚动（头部 ~40 + 480 ≈ 520，与旧固定高度相当）。
    private let maxBodyHeight: CGFloat = 480

    private var meta: ProviderMeta { ProviderMetaLookup.meta(for: providerId) }
    private var brand: Color { Color(hex: meta.brandColor) }
    /// 成本按「等效 API 费用」展示（≈$）：Claude 订阅 + Codex（ChatGPT 订阅 plan=plus）。
    private var isSub: Bool { providerId == "claude-sub" || providerId == "codex" }

    private var pal: DetailPalette { .of(scheme) }

    /// 强调色：Claude 订阅按设计稿调过的赭石橙（浅 #C85A2B / 深 #E8794F，比原始 brand
    /// #D97757 更沉、浅底对比更好）；其它 provider 退回各自 brand。
    private var accent: Color {
        if providerId == "claude-sub" {
            return scheme == .dark ? Color(hex: "#E8794F") : Color(hex: "#C85A2B")
        }
        // Codex：品牌绿按设计稿调过深浅两档（浅 #0C8163 加深保小字对比 / 深 #34BE95 提亮），
        // 非原始 brand #10A37F（小字对比不足）。
        if providerId == "codex" {
            return scheme == .dark ? Color(hex: "#34BE95") : Color(hex: "#0C8163")
        }
        return brand
    }
    private var accentBg: Color { accent.opacity(scheme == .dark ? 0.15 : 0.095) }
    private var greenBg: Color { pal.green.opacity(scheme == .dark ? 0.13 : 0.095) }
    /// 中性 segmented 容器底（周期切换器 + 用量/时间 共用）——中性灰避免 accentBg tint 在系统灰底上过亮。
    private var segBg: Color { Color.primary.opacity(scheme == .dark ? 0.08 : 0.06) }

    private var periodLabel: String {
        switch viewModel.window {
        case .today: return "今日"
        case .thisWeek: return "本周"
        case .last7Days: return "近 7 天"
        case .thisMonth: return "本月"
        case .last30Days: return "近 30 天"
        case .all: return "累计"
        case .custom: return "自定义"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            hairline
            detailContent
        }
        .frame(width: 400)
        .background(pal.bg)
    }

    /// 内容区：有数据时按实测高度自适应（矮不留白、高封顶滚动）；加载/空态给固定高度撑住弹层。
    @ViewBuilder private var detailContent: some View {
        if let d = viewModel.detail, d.providerId == providerId {
            if d.tokens.total == 0 {
                centered("该周期这个来源没有用量").frame(height: 220)
            } else {
                ScrollView {
                    detailBody(d)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: DetailHeightKey.self, value: g.size.height)
                        })
                }
                .frame(height: min(max(bodyHeight, 120), maxBodyHeight))
                .onPreferenceChange(DetailHeightKey.self) { bodyHeight = $0 }
            }
        } else {
            centered(nil).frame(height: 220)   // 加载中
        }
    }

    private var hairline: some View { Rectangle().fill(pal.divider).frame(height: 1) }

    // MARK: - 顶部返回栏（‹ 内联最左 + 图标 + 名称 + 周期 tag）

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.closeDetail() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回列表")

            ProviderIcon(providerId: providerId).frame(width: 20, height: 20)
            Text(meta.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pal.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            periodSwitcher
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// 周期切换器：直接切外层 tab（今日/本周/…），列表随之跟随；单窗口时退回静态标签。
    /// tab 集合复用列表同一套 `TabSettings.orderedWindows`（见 `TimeTabs.swift`）。
    /// 配色对齐周期 tag（`accentBg` 容器 + 未选 accent 文字 + 选中实心 accent 白字）。
    @ViewBuilder private var periodSwitcher: some View {
        let windows = tabSettings.orderedWindows
        if windows.count <= 1 {
            Text(windows.first?.tabLabel ?? periodLabel)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(segBg))
        } else {
            let sel = windows.contains(viewModel.window) ? viewModel.window : windows.first
            HStack(spacing: 2) {
                ForEach(windows, id: \.self) { win in
                    Button(action: { viewModel.changeWindowInDetail(win) }) {
                        Text(win.tabLabel)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(win == sel ? Color.white : pal.text2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(win == sel ? accent : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(segBg))
        }
    }

    private func centered(_ text: String?) -> some View {
        VStack(spacing: 8) {
            Spacer()
            if let text {
                Text(text).font(.system(size: 11)).foregroundStyle(pal.text2)
            } else {
                ProgressView().controlSize(.small)
                Text("统计中…").font(.system(size: 10)).foregroundStyle(pal.text3)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 主体

    private func detailBody(_ d: ProviderDetail) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            hero(d)
            // Codex 四维走「父块 + 子级」布局（输入⊃缓存输入、输出⊃思考）；其余走 Claude 2×2 图标格。
            if providerId == "codex" {
                codexMetricGrid(d)
            } else {
                metricGrid(d)
            }
            hairline
            modelsSection(d)
            hairline
            sessionsSection(d)
        }
    }

    // MARK: Hero

    private func hero(_ d: ProviderDetail) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fmtTok(d.tokens.total))
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(pal.text)
                (
                    Text("\(periodLabel)总量").font(.system(size: 11)).foregroundStyle(pal.text2)
                    + Text(" · ").font(.system(size: 11)).foregroundStyle(pal.text3)
                    + Text(heroCostLabel(d.cost))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                )
            }
            Spacer()
            CacheRing(ratio: ringRate(d.tokens), accent: accent, track: pal.track, text: pal.text, sub: pal.text3)
        }
    }

    /// 缓存命中率：Claude = cached/total（与主行一致）；
    /// Codex = 缓存命中 / 输入（cached/(净输入+cached)，即 prompt cache 命中率，语义更贴切）。
    private func ringRate(_ t: TokenBreakdown) -> Double {
        if providerId == "codex" {
            let fullInput = t.input + t.cacheRead
            return fullInput > 0 ? Double(t.cacheRead) / Double(fullInput) : 0
        }
        return t.hitRate
    }

    /// Hero 副行金额段：订阅口径 "≈ $X 等效"，API 变体 "$X"。
    private func heroCostLabel(_ c: Double) -> String {
        isSub ? "≈ \(fmtDollar(c)) 等效" : fmtDollar(c)
    }

    // MARK: 2×2 图标指标格

    private func metricGrid(_ d: ProviderDetail) -> some View {
        let t = d.tokens
        let inC = d.models.reduce(0.0) { $0 + Double($1.tokens.input) * ClaudePricing.inputRate(for: $1.modelId) }
        let outC = d.models.reduce(0.0) { $0 + Double($1.tokens.output) * ClaudePricing.outputRate(for: $1.modelId) }
        let crC = d.models.reduce(0.0) { $0 + Double($1.tokens.cacheRead) * ClaudePricing.inputRate(for: $1.modelId) * ClaudePricing.cacheReadMul }
        let cwC = d.models.reduce(0.0) { $0 + (Double($1.tokens.cacheCreate5m) * ClaudePricing.cacheWrite5mMul + Double($1.tokens.cacheCreate1h) * ClaudePricing.cacheWrite1hMul) * ClaudePricing.inputRate(for: $1.modelId) }
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                MetricTile(icon: "arrow.down", label: "净输入 (input)", value: fmtTok(t.input), cost: fmtCost(inC), accent: accent, accentBg: accentBg, pal: pal)
                MetricTile(icon: "arrow.up", label: "输出 (output)", value: fmtTok(t.output), cost: fmtCost(outC), accent: accent, accentBg: accentBg, pal: pal)
            }
            HStack(spacing: 10) {
                MetricTile(icon: "bolt.fill", label: "缓存读 (cache_read)", value: fmtTok(t.cacheRead), cost: fmtCost(crC), accent: accent, accentBg: accentBg, pal: pal)
                MetricTile(icon: "cylinder.split.1x2.fill", label: "缓存写 (cache_creation)", value: fmtTok(t.cacheCreate), cost: fmtCost(cwC), accent: accent, accentBg: accentBg, pal: pal)
            }
        }
    }

    // MARK: Codex 指标区（输入/输出 父块 + 缓存输入/思考 子级）

    /// Codex 四维口径下的指标区：两个父块并排（输入 / 输出），各自挂一条子级行
    /// （缓存输入 ⊂ 输入、思考 ⊂ 输出），对齐设计稿 D 布局。金额走 `CodexPricing`。
    private func codexMetricGrid(_ d: ProviderDetail) -> some View {
        let t = d.tokens
        // 逐模型用各自单价累加，避免混合模型时用单一价失真。
        let inputC = d.models.reduce(0.0) {
            $0 + Double($1.tokens.input) * CodexPricing.inputRate(for: $1.modelId)
               + Double($1.tokens.cacheRead) * CodexPricing.inputRate(for: $1.modelId) * CodexPricing.cachedInputMul
        }
        let cachedC = d.models.reduce(0.0) {
            $0 + Double($1.tokens.cacheRead) * CodexPricing.inputRate(for: $1.modelId) * CodexPricing.cachedInputMul
        }
        let outputC = d.models.reduce(0.0) { $0 + Double($1.tokens.output) * CodexPricing.outputRate(for: $1.modelId) }
        let reasoningC = d.models.reduce(0.0) { $0 + Double($1.tokens.reasoning) * CodexPricing.outputRate(for: $1.modelId) }
        let fullInput = t.input + t.cacheRead   // 输入(含缓存) = 净输入 + 缓存命中
        return HStack(spacing: 10) {
            CodexParentTile(
                icon: "arrow.down", label: "输入 (input)", value: fmtTok(fullInput), cost: fmtCost(inputC),
                childLabel: "缓存输入 (cached)", childValue: fmtTok(t.cacheRead), childCost: fmtCost(cachedC),
                accent: accent, accentBg: accentBg, pal: pal)
            CodexParentTile(
                icon: "arrow.up", label: "输出 (output)", value: fmtTok(t.output), cost: fmtCost(outputC),
                childLabel: "思考 (reasoning)", childValue: fmtTok(t.reasoning), childCost: fmtCost(reasoningC),
                accent: accent, accentBg: accentBg, pal: pal)
        }
    }

    // MARK: 分模型

    private func modelsSection(_ d: ProviderDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "按模型", count: d.modelCount, unit: "个模型")
            ForEach(d.models) { m in
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(m.displayName).font(.system(size: 11)).foregroundStyle(pal.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(fmtTok(m.tokens.total))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(pal.text2)
                        .frame(width: 56, alignment: .trailing)
                    hitPill(m.hitRate)
                    Text(fmtCost(m.cost))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(pal.text)
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    private func hitPill(_ r: Double) -> some View {
        Text(String(format: "%.0f%%", r * 100))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(pal.green)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(greenBg))
            .frame(width: 40, alignment: .center)
    }

    // MARK: 分会话

    private func sessionsSection(_ d: ProviderDetail) -> some View {
        let sorted = sortByTime ? d.sessions.sorted { $0.lastActivity > $1.lastActivity } : d.sessions
        let shown = showAllSessions ? sorted : Array(sorted.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("按会话").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.text2)
                Text("\(d.sessionCount) 个会话").font(.system(size: 9.5)).foregroundStyle(pal.text3)
                Spacer()
                sortToggle
            }
            ForEach(shown) { s in sessionRow(s) }
            if sorted.count > 3 {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAllSessions.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: showAllSessions ? "chevron.up" : "chevron.down").font(.system(size: 10))
                        Text(showAllSessions ? "收起（只看前 3 个）" : "展开全部（还有 \(sorted.count - 3) 个会话）")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(pal.text3)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private func sessionRow(_ s: SessionDetailRecord) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 11)).foregroundStyle(pal.text).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(s.subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(pal.text3)
                    if sortByTime {
                        Text("· \(s.lastActivity, format: .relative(presentation: .named, unitsStyle: .narrow))")
                            .font(.system(size: 9)).foregroundStyle(pal.text3)
                    }
                }
            }
            Spacer(minLength: 6)
            Text(fmtTok(s.tokens.total))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(pal.text2)
                .frame(width: 56, alignment: .trailing)
            Text(fmtCost(s.cost))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(pal.text)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var sortToggle: some View {
        HStack(spacing: 0) {
            toggleSeg("用量", active: !sortByTime) { sortByTime = false }
            toggleSeg("时间", active: sortByTime) { sortByTime = true }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 5).fill(segBg))
    }

    private func toggleSeg(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(active ? Color.white : pal.text2)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? accent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(title: String, count: Int, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.text2)
            Text("\(count) \(unit)").font(.system(size: 9.5)).foregroundStyle(pal.text3)
            Spacer()
        }
    }

    // MARK: - 格式化

    private func fmtTok(_ n: Int) -> String {
        if n <= 0 { return "0" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func fmtCost(_ c: Double) -> String {
        // 订阅口径 = 等效 API 费用，统一 ≈$ 前缀；API 变体是真实费用，$ 前缀
        let p = isSub ? "≈$" : "$"
        if c >= 10 { return String(format: "\(p)%.0f", c) }
        if c >= 1 { return String(format: "\(p)%.1f", c) }
        if c > 0 { return String(format: "\(p)%.2f", c) }
        return "\(p)0"
    }

    /// 纯 $ 金额（无 ≈ 前缀），Hero 副行金额段自带 ≈ 时用
    private func fmtDollar(_ c: Double) -> String {
        if c >= 10 { return String(format: "$%.0f", c) }
        if c >= 1 { return String(format: "$%.1f", c) }
        if c > 0 { return String(format: "$%.2f", c) }
        return "$0"
    }
}

// MARK: - 详情内容高度测量（驱动弹层自适应）

private struct DetailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - 详情页设计色板（跟随浅/深主题，对齐 .pen 变量表）

private struct DetailPalette {
    // 系统中性灰配色（对齐 macOS 原生窗口，避免暖色底过亮）。accent（Claude 橙 / Codex 绿）在视图层单独给。
    let bg: Color        // 页面底：系统窗口灰 #ECECEC / #1E1E1E
    let card: Color      // 卡片底：#FFFFFF / #2C2C2C
    let text: Color      // 一级文字：#1D1D1F / #F5F5F7
    let text2: Color     // 二级文字：#636366 / #98989D
    let text3: Color     // 三级文字：#8E8E93 / #636366
    let green: Color     // 命中绿：#2F9E6B / #66C08C
    let divider: Color   // 分割线：black0.08 / white0.09
    let track: Color     // 环轨道：black0.07 / white0.09

    static func of(_ scheme: ColorScheme) -> DetailPalette {
        if scheme == .dark {
            return DetailPalette(
                bg: Color(hex: "#1E1E1E"), card: Color(hex: "#2C2C2C"),
                text: Color(hex: "#F5F5F7"), text2: Color(hex: "#98989D"), text3: Color(hex: "#636366"),
                green: Color(hex: "#66C08C"),
                divider: Color.white.opacity(0.09), track: Color.white.opacity(0.09))
        }
        return DetailPalette(
            bg: Color(hex: "#ECECEC"), card: Color(hex: "#FFFFFF"),
            text: Color(hex: "#1D1D1F"), text2: Color(hex: "#636366"), text3: Color(hex: "#8E8E93"),
            green: Color(hex: "#2F9E6B"),
            divider: Color.black.opacity(0.08), track: Color.black.opacity(0.07))
    }
}

// MARK: - 缓存命中环

private struct CacheRing: View {
    let ratio: Double
    let accent: Color
    let track: Color
    let text: Color
    let sub: Color

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 5.5)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, ratio)))
                .stroke(accent, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(String(format: "%.1f%%", ratio * 100))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(text)
                Text("缓存命中").font(.system(size: 7.5)).foregroundStyle(sub)
            }
        }
        .frame(width: 58, height: 58)
    }
}

// MARK: - Token 指标格一格

private struct MetricTile: View {
    let icon: String
    let label: String
    let value: String
    let cost: String
    let accent: Color
    let accentBg: Color
    let pal: DetailPalette

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            RoundedRectangle(cornerRadius: 7).fill(accentBg)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9)).foregroundStyle(pal.text3).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(pal.text)
                    Text(cost).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(pal.text2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.card))
    }
}

// MARK: - Codex 父块（Top + 分隔线 + └ 子级行）

/// Codex 指标父块：顶部（图标 + 标签 + 数值 + 金额，同 `MetricTile`）+ 分隔线 + 缩进子级行。
/// 子级行字号收小一档（示从属），窄列下 label 截断不换行。对齐设计稿 D 布局。
private struct CodexParentTile: View {
    let icon: String
    let label: String        // 输入 (input)
    let value: String        // 33.0M
    let cost: String         // ≈$82
    let childLabel: String   // 缓存输入 (cached)
    let childValue: String   // 20.8M
    let childCost: String    // ≈$21
    let accent: Color
    let accentBg: Color
    let pal: DetailPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 7).fill(accentBg)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 9)).foregroundStyle(pal.text3).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(pal.text)
                        Text(cost).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(pal.text2)
                    }
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(pal.divider).frame(height: 1)
            HStack(spacing: 5) {
                Text("└").font(.system(size: 11)).foregroundStyle(pal.text3)
                Text(childLabel).font(.system(size: 8.5)).foregroundStyle(pal.text3).lineLimit(1)
                Spacer(minLength: 4)
                Text(childValue).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(pal.text2)
                Text(childCost).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(pal.text3)
            }
            .padding(.leading, 4)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.card))
    }
}
