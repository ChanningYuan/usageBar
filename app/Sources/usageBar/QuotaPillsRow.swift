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
            HStack(spacing: 7) {
                ForEach(Array(snap.windows.enumerated()), id: \.offset) { _, w in
                    pill(w, stale: stale)
                }
                Spacer(minLength: 0)
            }
        } else if let err = snap.error {
            grayLine(err)
        }
    }

    /// 像素对齐设计稿 p2Tk2/xmDgf/u83g7R（浅）· K600r（深）：
    /// 标签固定灰、重置更浅灰、底色是色档色的低透明度（浅 0x18≈0.094 / 深 0x26≈0.15）。
    private func pill(_ w: RateLimitWindow, stale: Bool) -> some View {
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
            if let reset = QuotaFormat.resetText(w.resetsAt, stale: stale) {
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

    /// 纯倒计时字符串（无「重置」字样）："3h15m" / "2d6h" / "17d"。到点/陈旧返回 nil。
    static func countdown(_ resetsAt: Date?, stale: Bool, now: Date = Date()) -> String? {
        guard !stale, let resetsAt else { return nil }
        let s = Int(resetsAt.timeIntervalSince(now))
        if s <= 0 { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 主列表药丸短文案："(3h15m 重置)"。陈旧不显示。
    static func resetText(_ resetsAt: Date?, stale: Bool, now: Date = Date()) -> String? {
        guard !stale, resetsAt != nil else { return nil }
        guard let cd = countdown(resetsAt, stale: stale, now: now) else { return "(即将重置)" }
        return "(\(cd) 重置)"
    }

    /// 详情页额度行长文案："4h15m 后重置"（对齐设计稿 p8ma3 的 q 行）。陈旧不显示。
    static func resetTextLong(_ resetsAt: Date?, stale: Bool, now: Date = Date()) -> String? {
        guard !stale, resetsAt != nil else { return nil }
        guard let cd = countdown(resetsAt, stale: stale, now: now) else { return "即将重置" }
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
