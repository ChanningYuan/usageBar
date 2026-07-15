import AppKit
import SwiftUI
import usageBarCore
import usageBarProviders

/// Provider 详情页（drill-in）——图标格版：Hero + 缓存命中环 + Token 2×2 图标格
/// + 分模型（命中率 pill + 花费）+ 分会话（排序 + 展开全部/收起）。
/// Claude Code / Codex / OpenCode 共用；各自明细由对应 scanner 懒加载。
///
/// 色板 / 字号严格对齐设计稿 `展开明细-分镜.pen`（YMWLk 浅 / MvCZv 深）：
/// 强调色浅 #C85A2B / 深 #E8794F，文字三级 text/text2/text3，卡片 lCard/dCard 等。
struct ProviderDetailView: View {
    @ObservedObject var viewModel: UsageViewModel
    let providerId: String
    @ObservedObject private var quotaStore = RateLimitStore.shared
    @ObservedObject private var quotaSettings = RateLimitSettings.shared

    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var tabSettings = TabSettings.shared
    @State private var sortByTime = false
    @State private var showAllSessions = false
    @State private var showAllModels = false
    @State private var showAllSources = false

    /// 明细区折叠阈值：默认只显示前 N 条，多出来的收进「展开全部」。
    /// 按模型 / 按会话 / 按来源**共用同一套**（v0.3.23 起）——此前只有「按会话」有折叠，
    /// 「按模型」全量铺开，Claude Code 累计 7 个模型时把页面撑爆。
    private let collapsedLimit = 3
    /// 详情内容实测高度（驱动弹层自适应，避免内容矮时底部留白）。
    @State private var bodyHeight: CGFloat = 0
    /// 内容区高度上限：超过则封顶滚动（头部 ~40 + 480 ≈ 520，与旧固定高度相当）。
    private let maxBodyHeight: CGFloat = 480

    private var meta: ProviderMeta { ProviderMetaLookup.meta(for: providerId) }
    private var brand: Color { Color(hex: meta.brandColor) }

    /// provider 声明表（指标块清单 / 门禁 / 金额档 / 强调色 / 扫描器）。见 `ProviderDetailSpec.swift`。
    /// 门禁保证只有有声明的 provider 才能进到这里；兜底给 Claude Code 形态，不崩。
    private var spec: ProviderDetailSpec {
        ProviderDetailRegistry.spec(for: providerId)
            ?? ProviderDetailRegistry.specs["claude-code"]!
    }

    /// 是否展示「等效 API 费用」（≈$ 前缀）。三档金额口径见 `CostUnit`。
    private var usesEquivalentCost: Bool { spec.costUnit == .equivalentUSD }

    private var pal: DetailPalette { .of(scheme) }

    /// 强调色：一律走声明表的深浅两档（原始品牌色小字对比普遍不足，见 `ProviderDetailSpec`）。
    private var accent: Color { spec.accent(scheme) }
    private var accentBg: Color { accent.opacity(scheme == .dark ? 0.15 : 0.095) }
    /// 实心 accent 之上的文字色（按亮度自动选深/白）。Cursor 的银灰 accent 配白字会糊。
    private var onAccent: Color { spec.onAccent(scheme) }
    private var greenBg: Color { pal.green.opacity(scheme == .dark ? 0.13 : 0.095) }
    /// 中性 segmented 容器底（周期切换器 + 用量/时间 共用）——中性灰避免 accentBg tint 在系统灰底上过亮。
    private var segBg: Color { Color.primary.opacity(scheme == .dark ? 0.08 : 0.06) }
    /// 周期切换器选中态背景（中性浅色卡片，同主列表 segmented；不用 accent 实心）
    private var selectedTabBg: Color { scheme == .dark ? Color.white.opacity(0.16) : Color.white }

    private var periodLabel: String {
        switch viewModel.window {
        case .today: return "今日"
        case .yesterday: return "昨日"
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
            // M0 账号额度：在周期切换器【之上】—— 结构本身说清「不随周期变」，不用小字打补丁。
            accountQuotaModule
            // 周期切换器下沉为独立一行、撑满宽度 —— 管辖范围自明：以下随周期变，以上不变。
            periodBar
            hairline
            detailContent
            hairline
            footer
        }
        .frame(width: 440)
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
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - M0 账号额度模块 + 周期切换栏 + footer（v0.3.24）

    /// M0 账号额度：Hero 之上、周期切换器之上。三态——正常 / 未开启引导 / 错误态说明。
    /// 只对「有额度数据源」的 provider 显示（Cowork/OpenCode/悟空/WorkBuddy 无，整块不出现）。
    @ViewBuilder private var accountQuotaModule: some View {
        if RateLimitSettings.logicalKey(forProvider: providerId) != nil {
            let snap = quotaStore.snapshot(for: providerId)
            if !quotaSettings.isEnabled(forProvider: providerId) {
                quotaBox {
                    quotaNoteRow("未开启额度监测", action: "去开启 ›")
                }
            } else if let snap, !snap.windows.isEmpty {
                let stale = QuotaFormat.isStale(snap.capturedAt)
                let hoisted = QuotaFormat.hoistedReset(snap.windows)
                // 头行按设计稿 bafX0 复原：「账号额度」标签 + plan 标签（Max/prolite…）。
                // 设计里「账号级·不随周期切换」那句是关掉的，故不显示。
                quotaBox {
                    HStack(spacing: 6) {
                        Text("账号额度")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.text2)
                        if let plan = snap.planType, !plan.isEmpty {
                            Text(plan)
                                .font(.system(size: 8, weight: .semibold)).foregroundStyle(pal.text2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        }
                        Spacer()
                        // 区头右槽：陈旧说明优先（解释「为什么灰」），否则放上提的重置时间（0715 定稿 B3）
                        if stale {
                            Text(QuotaFormat.staleNote(snap.capturedAt) + Self.staleHint(for: snap.providerId))
                                .font(.system(size: 9)).foregroundStyle(pal.text3)
                        } else if let t = QuotaFormat.resetTextLong(hoisted) {
                            Text(t)
                                .font(.system(size: 9)).foregroundStyle(pal.text3)
                        }
                    }
                    ForEach(Array(snap.windows.enumerated()), id: \.offset) { _, w in
                        quotaWindowRow(w, stale: stale, hideReset: hoisted != nil)
                    }
                }
            } else if let err = snap?.error {
                quotaBox { quotaNoteRow(QuotaFormat.errorText(err), action: nil) }
            }
        }
    }

    private func quotaBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .padding(.horizontal, 12).padding(.top, 10)
    }

    private func quotaNoteRow(_ text: String, action: String?) -> some View {
        HStack(spacing: 6) {
            Text("账号额度")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.text2)
            Text(text).font(.system(size: 9)).foregroundStyle(pal.text3)
            Spacer()
            if let action {
                Button(action) {
                    SettingsNavigation.shared.requestFocusQuota()   // 打开设置后定位到「账号额度」段
                    SettingsWindowController.shared.showWindow()
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    /// 像素对齐设计稿 p8ma3 的额度行（q-5 小时 / q-7 天 / q-Fable）：
    /// 中文窗口标签(52w) + 轨道 + 百分比(34w) + 数字列(86w，有 detail 才有) + 「X 后重置」(92w)。
    /// hideReset = 重置已上提区头（0715 定稿 B3），整列不渲染、轨道加长。
    private func quotaWindowRow(_ w: RateLimitWindow, stale: Bool, hideReset: Bool = false) -> some View {
        let w = QuotaFormat.displayWindow(w)   // 重置点已过 → 按已用 0% 展示（空条 + 「已重置」）
        let color = stale ? Color.secondary : QuotaFormat.color(w, scheme: scheme)
        return HStack(spacing: 8) {
            Text(Self.detailWindowLabel(w))
                .font(.system(size: 10))
                .foregroundStyle(pal.text2)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * min(1, w.usedPercent / 100)))
                }
            }
            .frame(height: 5)
            Text("\(Int(w.usedPercent.rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 34, alignment: .trailing)
            // used/total 数字列（Qoder 有 detail，Claude/Codex 无 → 列整体缺席，不占宽）
            // 0715 对焦稿定稿 B1：行内一列、mono 右对齐；进度条变短的代价已过目拍板
            if let d = w.detail {
                Text(d)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(pal.text)
                    .frame(width: 86, alignment: .trailing)
            }
            if !hideReset {
                Text(QuotaFormat.resetTextLong(w.resetsAt) ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(pal.text3)
                    .frame(width: 92, alignment: .trailing)
            }
        }
    }

    /// 陈旧说明的补救提示：statusline 源只在 Claude 会话开着时写数据，指条明路；其余源等自动重试即可
    private static func staleHint(for providerId: String) -> String {
        guard providerId == "claude-code",
              RateLimitSettings.shared.dataSources["claude-code"] == "statusline" else { return "" }
        return " · 打开 Claude 会话后自动更新"
    }

    /// 详情页额度行的中文窗口标签（主列表药丸仍用 5h/7d 缩写；模型名如 Fable 原样）。
    private static func detailWindowLabel(_ w: RateLimitWindow) -> String {
        switch w.label {
        case "5h": return "5 小时"
        case "7d": return "7 天"
        case "1h": return "1 小时"
        case "1d": return "1 天"
        case "3d": return "3 天"
        case "30d": return "30 天"
        default: return w.label
        }
    }

    /// 周期切换器独立一行、撑满宽度。原在 header 里，下沉后管辖范围自明（以上不随周期变，以下变）。
    private var periodBar: some View {
        periodSwitcher
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// 底部工具栏：刷新时间 + 设置/刷新。**不显示合计**——Hero 已有该 provider 周期总量，重复。
    private var footer: some View {
        HStack(spacing: 8) {
            // 刷新时间居中 —— 与主列表 footer 保持一致（两侧 Spacer 夹住，位置对齐）
            Spacer()
            if let last = viewModel.lastRefreshAt {
                Text("\(last, format: .relative(presentation: .named, unitsStyle: .wide)) 刷新")
                    .font(.system(size: 10))
                    .foregroundStyle(pal.text3)
            }
            Spacer()
            Button(action: { SettingsWindowController.shared.showWindow() }) {
                Image(systemName: "gearshape").font(.system(size: 10)).foregroundStyle(pal.text2)
            }.buttonStyle(.plain)
            Button(action: { Task { await viewModel.refresh() } }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundStyle(pal.text2)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
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
                            .foregroundStyle(win == sel ? pal.text : pal.text2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(win == sel ? selectedTabBg : Color.clear))
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

    /// 照 `spec.metricRows` 渲染，不再按 provider 分叉（原先是 codexMetricGrid /
    /// openCodeMetricGrid / metricGrid 三个近乎重复的函数，加 7 个 provider 会变成 10 个）。
    private func detailBody(_ d: ProviderDetail) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            hero(d)
            metricGrid(d)
            if spec.hasSources, d.sourceCount >= 2 {
                hairline
                sourcesSection(d)
            }
            hairline
            modelsSection(d)
            // Cursor 无会话维度（本地 mirror 无 conversationId）→ 整块缺席
            if spec.hasSessions {
                hairline
                sessionsSection(d)
            }
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

    /// 缓存命中率口径由声明表给（`.ofTotal` Claude 系 / `.ofInput` Codex 系）。
    private func ringRate(_ t: TokenBreakdown) -> Double { spec.ring.rate(t) }

    /// Hero 副行金额段。三档各自的措辞。
    private func heroCostLabel(_ c: Double) -> String {
        switch spec.costUnit {
        case .equivalentUSD:
            return "≈ \(fmtDollar(c))"
        case .credits:
            // 数据自带的内部积分（WorkBuddy），不查价目表
            let n = c >= 100 ? String(format: "%.0f", c)
                  : c >= 1  ? String(format: "%.1f", c)
                            : String(format: "%.2f", c)
            return "≈ \(n) Credits"
        case .unavailable:
            // 模型名被厂商打码（qmodel），价目表永远查不到；本地也没有 credit
            return "无价目"
        }
    }

    // MARK: 指标区（照 spec.metricRows 渲染，provider 只声明块清单）

    /// 三种既有形态——Claude 独立格 ×4 / Codex 父块 ×2 / OpenCode 独立格 ×3 + 父块 ×1——
    /// 现在全部由**同一份清单**表达，视觉与重构前逐像素一致（这是本次抽象的验收标准）。
    /// 单价逐模型走 `UnifiedPricing` 跨厂商路由，算法见 `MetricKind.cost`。
    private func metricGrid(_ d: ProviderDetail) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(spec.metricRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, block in
                        metricBlockView(block, d)
                    }
                }
                // 行内可能混高（独立格 + 父块并排），fixedSize 让矮格撑满行高、顶部对齐
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func metricBlockView(_ block: MetricBlock, _ d: ProviderDetail) -> some View {
        switch block {
        case .tile(let kind):
            MetricTile(
                icon: kind.icon, label: kind.tileLabel,
                value: fmtTok(kind.value(d.tokens)), cost: metricCost(kind.cost(d.models)),
                accent: accent, accentBg: accentBg, pal: pal)
        case .parent(let kind, let child):
            ParentTile(
                icon: kind.icon, label: kind.tileLabel,
                value: fmtTok(kind.value(d.tokens)), cost: metricCost(kind.cost(d.models)),
                childLabel: child.childLabel,
                childValue: fmtTok(child.value(d.tokens)), childCost: metricCost(child.cost(d.models)),
                accent: accent, accentBg: accentBg, pal: pal)
        }
    }

    // MARK: 按来源（仅 Claude Code 两类都有流量时显示）

    private func sourcesSection(_ d: ProviderDetail) -> some View {
        collapsibleSection(title: "按来源", unit: "个来源",
                           items: d.sources, expanded: $showAllSources,
                           trailing: { EmptyView() }) { source in
            HStack(spacing: 8) {
                Circle().fill(sourceColor(source.source)).frame(width: 7, height: 7)
                Text(sourceName(source.source))
                    .font(.system(size: 11))
                    .foregroundStyle(pal.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(fmtTok(source.tokens.total))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(pal.text2)
                    .frame(width: 56, alignment: .trailing)
                hitPill(source.hitRate)
                Text(fmtCost(source.cost))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(pal.text)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    // MARK: - 通用「可折叠明细区」（按模型 / 按会话 / 按来源共用）

    /// 段头（标题 + 计数 + 可选右侧控件）+ 前 N 行 + 展开/收起按钮。
    ///
    /// 抽成一处的理由：折叠这件事和「这一区装的是模型还是会话」无关，
    /// 它只关心「有多少行、显示几行」。原先只有按会话写了折叠逻辑，按模型直接全量 `ForEach`，
    /// 于是模型一多页面就被撑爆——**同一个交互写两遍，必然有一边被漏掉**。
    @ViewBuilder
    private func collapsibleSection<T: Identifiable, Row: View, Trailing: View>(
        title: String, unit: String, items: [T], expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder row: @escaping (T) -> Row
    ) -> some View {
        let shown = expanded.wrappedValue ? items : Array(items.prefix(collapsedLimit))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.text2)
                Text("\(items.count) \(unit)").font(.system(size: 9.5)).foregroundStyle(pal.text3)
                Spacer()
                trailing()
            }
            ForEach(shown) { row($0) }
            if items.count > collapsedLimit {
                expandButton(expanded: expanded, hidden: items.count - collapsedLimit, unit: unit)
            }
        }
    }

    private func expandButton(expanded: Binding<Bool>, hidden: Int, unit: String) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() } }) {
            HStack(spacing: 4) {
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                Text(expanded.wrappedValue
                     ? "收起（只看前 \(collapsedLimit) 个）"
                     : "展开全部（还有 \(hidden) \(unit)）")
                    .font(.system(size: 10))
            }
            .foregroundStyle(pal.text3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func sourceName(_ source: ClaudeSource) -> String {
        switch source {
        case .official: return "官方直连 (Anthropic)"
        case .relay: return "中转/代理"
        }
    }

    private func sourceColor(_ source: ClaudeSource) -> Color {
        switch source {
        case .official: return accent
        case .relay: return Color(hex: scheme == .dark ? "#9F7ACB" : "#6F4A8A")
        }
    }

    // MARK: 分模型

    private func modelsSection(_ d: ProviderDetail) -> some View {
        // v0.3.23：与「按会话」一样默认只显示前 3 个（Claude Code 累计有 7 个模型，全铺开撑爆页面）
        collapsibleSection(title: "按模型", unit: "个模型",
                           items: d.models, expanded: $showAllModels,
                           trailing: { EmptyView() }) { m in
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(m.modelId).font(.system(size: 11)).foregroundStyle(pal.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(fmtTok(m.tokens.total))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(pal.text2)
                    .frame(width: 56, alignment: .trailing)
                hitPill(m.hitRate)
                if m.cost == 0, m.tokens.total > 0, UnifiedPricing.hasNoPricing(for: m.modelId) {
                    // 内置+远程价目都没有的模型：给反馈入口（预填 issue），感知长尾缺价
                    Button(action: { openPricingIssue(model: m.modelId) }) {
                        Text("无价目")
                            .font(.system(size: 9))
                            .foregroundStyle(pal.text3)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(pal.text3.opacity(0.45), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("该模型暂无价目，点击一键反馈（打开预填好的 GitHub Issue）")
                    .frame(width: 46, alignment: .trailing)
                } else {
                    Text(fmtCost(m.cost))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(pal.text)
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    /// 打开预填好的「价目缺失」GitHub Issue（用户只需点 Submit）
    private func openPricingIssue(model: String) {
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let body = """
        - 模型 id: `\(model)`
        - 来源: \(providerId)
        - usageBar 版本: \(ver)

        该模型的等效花费显示为 $0（内置与远程价目表均未收录），请补充价格。
        """
        var comp = URLComponents(string: "https://github.com/ChanningYuan/usageBar/issues/new")!
        comp.queryItems = [
            .init(name: "title", value: "[价目缺失] \(model)"),
            .init(name: "body", value: body),
        ]
        if let url = comp.url { NSWorkspace.shared.open(url) }
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
        return collapsibleSection(title: "按会话", unit: "个会话",
                                  items: sorted, expanded: $showAllSessions,
                                  trailing: { sortToggle }) { s in
            sessionRow(s)
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
            // v0.3.22 新增：会话也显示缓存命中率。数据现成（tokens 就是 5 列拆分），
            // 一眼看出哪个会话吃缓存、哪个在烧新 token。
            // ⚠️ 用 `tokens.hitRate`（cached/total）而非 `ringRate` —— 与紧邻的「按模型」行
            // （`m.hitRate`）**同口径**，避免同一页两个药丸算法不同。
            // （Codex 的 Hero 环用的是另一套 cached/输入，是重构前就有的口径分歧，本版不动。）
            hitPill(s.tokens.hitRate)
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
                .foregroundStyle(active ? onAccent : pal.text2)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? accent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    // MARK: - 格式化

    private func fmtTok(_ n: Int) -> String {
        if n <= 0 { return "0" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// 金额三档（`CostUnit`）：
    /// - `.equivalentUSD` → `≈$12.3`（token × 价目表单价）
    /// - `.credits`       → `6.78 Cr`（数据自带的信用点；**不查价目表**）
    /// - `.unavailable`   → `—`（模型名被厂商打码 + 本地无 credit，如 Qoder 全家桶）
    private func fmtCost(_ c: Double) -> String {
        switch spec.costUnit {
        case .unavailable:
            return "—"
        case .credits:
            // credit 是整条消息的标量，**拆不到四列** → 指标区格子里不显示（见 metricCost）
            if c >= 100 { return String(format: "%.0f Cr", c) }
            if c >= 1 { return String(format: "%.1f Cr", c) }
            return c > 0 ? String(format: "%.2f Cr", c) : "0 Cr"
        case .equivalentUSD:
            if c >= 10 { return String(format: "≈$%.0f", c) }
            if c >= 1 { return String(format: "≈$%.1f", c) }
            if c >= 0.01 { return String(format: "≈$%.2f", c) }
            // <1 美分给 3 位小数——有量却显示 "0.00" 像 bug（如 7.7K 缓存读 = $0.004）
            if c > 0 { return String(format: "≈$%.3f", c) }
            return "≈$0"
        }
    }

    /// 指标区格子里的金额。`.credits` 档下**必须是 `—`**：
    /// credit 是整条消息的一个标量，**拆不到「净输入/输出/缓存读/缓存写」四列**
    /// （等效美元能拆，是因为每列各有单价）。硬按四列摊会是编造。
    private func metricCost(_ c: Double) -> String {
        spec.costUnit == .credits ? "—" : fmtCost(c)
    }

    /// 纯 $ 金额（无 ≈ 前缀），Hero 副行金额段自带 ≈ 时用
    private func fmtDollar(_ c: Double) -> String {
        if c >= 10 { return String(format: "$%.0f", c) }
        if c >= 1 { return String(format: "$%.1f", c) }
        if c >= 0.01 { return String(format: "$%.2f", c) }
        if c > 0 { return String(format: "$%.3f", c) }
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
        // maxHeight 让混高行（OpenCode 独立格 + 父块并排）里卡片撑满行高，topLeading 使
        // 图标/标题与邻格父块顶部区同高；常规等高行内容即高度、对齐方式无感
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.card))
    }
}

// MARK: - 指标父块（Top + 分隔线 + └ 子级行）

/// 「父块 ⊃ 子级」指标块：顶部（图标 + 标签 + 数值 + 金额，同 `MetricTile`）+ 分隔线 + 缩进子级行。
/// 子级行字号收小一档（示从属），窄列下 label 截断不换行。对齐设计稿 D 布局。
/// 用于表达**子集关系**：Codex 的 输入 ⊃ 缓存输入、输出 ⊃ 思考；OpenCode / WorkBuddy 的 输出 ⊃ 思考。
/// （原名 `CodexParentTile`，v0.3.22 抽象后已非 Codex 专属，改名 `ParentTile`。）
private struct ParentTile: View {
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
