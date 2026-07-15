import SwiftUI
import usageBarCore

/// 主列表 provider 行下方的「额度药丸子行」（v0.3.24）。
///
/// 只在**今日 tab + 已开启监测 + 有快照**时渲染（调用侧已判今日 tab）。
/// 一行并排多颗药丸：窗口标签 + 百分比（色档）+ (倒计时 重置)。
/// 色档优先跟官方 severity（Claude 有），无 severity 用本地阈值（Codex/Cursor/Qoder）。
struct QuotaPillsRow: View {
    let providerId: String
    @ObservedObject private var store = RateLimitStore.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let snap = store.snapshot(for: providerId) {
            content(snap)
                .padding(.leading, 32)   // 与上方名称对齐（icon 22 + gap 10）
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func content(_ snap: RateLimitSnapshot) -> some View {
        if !snap.windows.isEmpty {
            let stale = QuotaFormat.isStale(snap.capturedAt)
            let hoisted = QuotaFormat.hoistedReset(snap.windows)
            HStack(spacing: 7) {
                ForEach(Array(snap.windows.enumerated()), id: \.offset) { _, w in
                    pill(w, stale: stale, hideReset: hoisted != nil)
                }
                // 上提的重置时间缀行尾（0715 定稿 P3）：一次只写一遍，药丸更短
                if hoisted != nil {
                    Text(QuotaFormat.countdownCoarse(hoisted).map { "\($0) 重置" } ?? "已重置")
                        .font(.system(size: 8))
                        .foregroundStyle(Color(hex: scheme == .dark ? "#636366" : "#8E8E93"))
                }
                Spacer(minLength: 0)
            }
        } else if let err = snap.error {
            grayLine(err)
        }
    }

    /// 像素对齐设计稿 p2Tk2/xmDgf/u83g7R（浅）· K600r（深）：
    /// 标签固定灰、重置更浅灰、底色是色档色的低透明度（浅 0x18≈0.094 / 深 0x26≈0.15）。
    private func pill(_ w: RateLimitWindow, stale: Bool, hideReset: Bool = false) -> some View {
        let w = QuotaFormat.displayWindow(w)   // 重置点已过 → 按已用 0% 展示
        let color = stale ? Color.secondary : QuotaFormat.color(w, scheme: scheme)
        let labelColor = Color(hex: scheme == .dark ? "#98989D" : "#636366")
        let resetColor = Color(hex: scheme == .dark ? "#636366" : "#8E8E93")
        return HStack(spacing: 4) {
            Text(w.label)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(labelColor)
            Text("\(Int(w.usedPercent.rounded()))%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            // used/total 数字（0715 对焦稿定稿 P1）：Qoder 双药丸带数字实测 ~325pt < 可用 340pt
            if let d = w.detail {
                Text(d)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(labelColor)
            }
            if !hideReset, let reset = QuotaFormat.resetText(w.resetsAt) {
                Text(reset)
                    .font(.system(size: 8))
                    .foregroundStyle(resetColor)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(scheme == .dark ? 0.15 : 0.094)))
    }

    @ViewBuilder
    private func grayLine(_ err: RateLimitError) -> some View {
        HStack(spacing: 4) {
            Text(QuotaFormat.errorText(err))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            if err == .authDenied {
                // 授权被拒 → 去设置的「账号额度」段（切数据源 / 重置 / 重新授权都在那）
                Button("去授权 ›") {
                    SettingsNavigation.shared.requestFocusQuota()
                    SettingsWindowController.shared.showWindow()
                }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color(hex: "#007AFF"))
            } else if err == .credentialUnavailable {
                // 凭证失效 / 401 → 原地重试一次（多为瞬时）
                Button("重试 ›") {
                    if let key = RateLimitSettings.logicalKey(forProvider: providerId) {
                        Task { await RateLimitCoordinator.refreshOne(key) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color(hex: "#007AFF"))
            }
        }
    }
}

/// 额度展示的格式化 / 色档 / 陈旧判定（UI 层，不进 Core）。
enum QuotaFormat {
    /// 超过 2 个刷新周期（≈20 分钟）没刷到新快照 → 陈旧
    static let staleThreshold: TimeInterval = 20 * 60

    static func isStale(_ capturedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(capturedAt) > staleThreshold
    }

    /// 色档：优先官方 severity，无则本地阈值（≤60 绿 / 61–85 黄 / >85 红）
    static func color(_ w: RateLimitWindow, scheme: ColorScheme) -> Color {
        let green = Color(hex: scheme == .dark ? "#66C08C" : "#1F8A54")
        let yellow = Color(hex: scheme == .dark ? "#E8A54B" : "#B57314")
        let red = Color(hex: scheme == .dark ? "#FF6459" : "#D1372B")
        if let sev = w.severity?.lowercased() {
            switch sev {
            case "warning": return yellow
            case "critical", "exceeded", "reached", "error": return red
            default: return green
            }
        }
        switch w.usedPercent {
        case ..<60: return green
        case ..<85: return yellow
        default: return red
        }
    }

    /// 纯倒计时字符串（无「重置」字样）："3h15m" / "2d6h" / "17d"。已过重置点返回 nil。
    /// ⚠️ resets_at 是**绝对时间戳**，对 now 实时计算——陈旧快照下倒计时依然为真，
    /// 不因陈旧隐藏（0715 用户指正；陈旧只置灰百分比 + 区头出说明）。
    static func countdown(_ resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let s = Int(resetsAt.timeIntervalSince(now))
        if s <= 0 { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 药丸用的粗粒度倒计时：只取最高一位（"6d" / "22h" / "35m"）。
    /// 0715 用户反馈："6d22h 重置" 带天带时信息过载——主列表扫一眼只需要量级，精确值在详情页。
    static func countdownCoarse(_ resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let s = Int(resetsAt.timeIntervalSince(now))
        if s <= 0 { return nil }
        let d = s / 86400, h = (s % 86400) / 3600
        if d > 0 { return "\(d)d" }
        if h > 0 { return "\(h)h" }
        return "\((s % 3600) / 60)m"
    }

    /// 主列表药丸短文案（粗粒度）："(6d 重置)"；重置点已过 → "(已重置)"
    /// （窗口已翻篇、新窗口重置时间未知，占位到下次数据刷新——statusline 源要等用户再开 Claude 会话）。
    static func resetText(_ resetsAt: Date?, now: Date = Date()) -> String? {
        guard resetsAt != nil else { return nil }
        guard let cd = countdownCoarse(resetsAt, now: now) else { return "(已重置)" }
        return "(\(cd) 重置)"
    }

    /// 重置点已过 → 已用归零的展示副本（0%、空条、无 severity）。
    /// 百分比语义统一是**已用**：窗口翻篇 = 额度恢复 = 已用 0%（显示 100% 会与「用满」撞语义，0715 验收对焦）。
    /// detail（used/total）一并清掉——那是旧窗口的数字；resetsAt 保留让「(已重置)」文案照常出。
    static func displayWindow(_ w: RateLimitWindow, now: Date = Date()) -> RateLimitWindow {
        guard let r = w.resetsAt, r.timeIntervalSince(now) <= 0 else { return w }
        return RateLimitWindow(kind: w.kind, label: w.label, windowMinutes: w.windowMinutes,
                               usedPercent: 0, resetsAt: w.resetsAt, scopeModel: w.scopeModel)
    }

    /// 陈旧说明（区头灰字）："更新于 9h 前"。数据几点采的说清楚，让灰色有解释。
    static func staleNote(_ capturedAt: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(capturedAt)))
        let t: String
        if s >= 86400 { t = "\(s / 86400)d" }
        else if s >= 3600 { t = "\(s / 3600)h" }
        else { t = "\(max(1, s / 60))m" }
        return "更新于 \(t) 前"
    }

    /// 重置时间上提规则（0715 定稿 B3/P3）：**恰好一个**窗口带重置时间时返回它——
    /// 详情页放到额度区头部、主列表缀在药丸行尾，行内/药丸内不再重复。
    /// Claude 这类多窗口、各自重置的仍返回 nil（每行各挂各的）。
    static func hoistedReset(_ windows: [RateLimitWindow]) -> Date? {
        let carriers = windows.compactMap(\.resetsAt)
        return carriers.count == 1 ? carriers[0] : nil
    }

    /// 详情页额度行长文案："4h15m 后重置"（对齐设计稿 p8ma3 的 q 行）；重置点已过 → "已重置"。
    static func resetTextLong(_ resetsAt: Date?, now: Date = Date()) -> String? {
        guard resetsAt != nil else { return nil }
        guard let cd = countdown(resetsAt, now: now) else { return "已重置" }
        return "\(cd) 后重置"
    }

    static func errorText(_ err: RateLimitError) -> String {
        switch err {
        case .credentialUnavailable: return "登录凭证已失效 ·"
        case .authDenied:            return "未获钥匙串授权 ·"
        case .network:               return "暂时无法获取额度"
        case .noQuotaData:           return "该账号类型不提供配额数据"
        case .noDataSource:          return "该工具未提供额度接口"
        case .awaitingData:          return "打开 Claude 会话后自动显示，或切「联网 API」立即看"
        }
    }
}
