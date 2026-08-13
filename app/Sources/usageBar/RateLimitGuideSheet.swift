import AppKit
import SwiftUI
import usageBarProviders

/// 开启 Claude / Qoder 额度或千问办公积分监测前的引导 sheet。
///
/// - **Claude**：三选一数据源（statusline 推荐 / CLI 抄屏 / OAuth 接口），确认按钮文案跟随选中项
///   （需钥匙串的 OAuth → 「去授权并启用」；零弹窗的 statusline/CLI → 「启用」）。
/// - **Qoder**：单方案（联网查额度，需一次钥匙串授权），按钮固定「去授权并启用」。
/// - **千问办公**：单方案（联网缓存真实积分账单，需一次钥匙串授权）。
/// - Codex / Cursor / WorkBuddy 不弹此 sheet（零选择、零钥匙串，直接开）。
///
/// 需钥匙串的选项会亮出**强调色提醒**：选「始终允许」+「仅查额度、绝不外发」。
struct RateLimitGuideSheet: View {
    let logicalId: String                 // "claude-code" / "qoder" / "qwen-work"
    @State private var selected: String   // Claude 的数据源选择；Qoder 恒为 ""
    let onConfirm: (_ source: String) -> Void
    let onCancel: () -> Void

    init(logicalId: String, initialSource: String,
         onConfirm: @escaping (_ source: String) -> Void, onCancel: @escaping () -> Void) {
        self.logicalId = logicalId
        self._selected = State(initialValue: initialSource)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var isClaude: Bool { logicalId == "claude-code" }
    private var isQwenWork: Bool { logicalId == "qwen-work" }

    /// statusline 预览图（Icons/statusline-preview.png，随 app 打包）
    private static let statuslineShot: NSImage? = BundleIconLoader.load(name: "statusline-preview", ext: "png")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if isClaude {
                    ForEach(Self.claudeOptions, id: \.source) { opt in
                        optionRow(opt)
                    }
                } else {
                    optionRow(isQwenWork ? Self.qwenWorkOption : Self.qoderOption)
                }
                if selectedOption.needsKeychain { keychainWarning }
            }
            .padding(16)
            Divider()
            footer
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 段

    private var header: some View {
        HStack(spacing: 8) {
            ProviderIcon(providerId: isClaude ? "claude-code" : (isQwenWork ? "qwen-work" : "qoder-work"))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) { onConfirm(isClaude ? selected : "") }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 选项行：单选圈 + 标题（推荐徽章）+ 说明。整行可点选。
    private func optionRow(_ opt: Option) -> some View {
        let isSel = isClaude ? (selected == opt.source) : true
        return Button {
            if isClaude { selected = opt.source }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: isSel ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSel ? Color(hex: "#007AFF") : Color.secondary)
                        .opacity(isClaude ? 1 : 0)   // 单方案不显 radio
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(opt.title).font(.system(size: 12, weight: .semibold))
                            if opt.recommended { badge("推荐") }
                            if opt.needsKeychain { badge("需授权", color: "#D97706") }
                        }
                        Text(opt.desc)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                // statusline 选项：预览图 + 说明。**占满整行**（对齐设计稿 UA0WJ/QakFN）。
                // 用真实宽高比算高度 + 宽度撑满卡片内宽，别用 aspectRatio(.fit)——它在这层嵌套里不会把图放大到整行。
                if opt.source == "statusline", let shot = Self.statuslineShot {
                    let cardInnerWidth: CGFloat = 410   // sheet 460 - content padding 32 - card padding 18
                    let h = cardInnerWidth * shot.size.height / max(shot.size.width, 1)
                    Image(nsImage: shot)
                        .resizable()
                        .frame(maxWidth: .infinity)
                        .frame(height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("↑ 加了那行后，你 Claude 会话里 statusline 长这样（额度行是新加的，其它不受影响）")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSel && isClaude ? Color(hex: "#007AFF").opacity(0.07) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSel && isClaude ? Color(hex: "#007AFF").opacity(0.35) : Color.secondary.opacity(0.15), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 需钥匙串时的强调提醒：始终允许 + 仅查询账号数据、不外发。
    private var keychainWarning: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "#D97706"))
            VStack(alignment: .leading, spacing: 2) {
                (Text("会弹出一次 macOS 钥匙串授权框，请点 ")
                 + Text("「始终允许」").foregroundColor(Color(hex: "#D97706")).bold()
                 + Text("（点「允许」的话每次刷新都会再弹一次）。"))
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
                Text("凭证只用于向对应服务查询你自己的账号额度或积分历史，绝不外发、不上传任何服务器。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: "#D97706").opacity(0.10)))
    }

    private func badge(_ text: String, color: String = "#007AFF") -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color(hex: color))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color(hex: color).opacity(0.12)))
    }

    // MARK: - 选项数据

    struct Option { let source: String; let title: String; let desc: String; let recommended: Bool; let needsKeychain: Bool }

    static let claudeOptions: [Option] = [
        .init(source: "statusline", title: "statusline 搭便车",
              desc: "往你的 statusline.sh 自动加一行，Claude 每刷新状态栏就把额度写到本地文件，usageBar 只读文件。零钥匙串、零起进程，最省心。",
              recommended: true, needsKeychain: false),
        .init(source: "cli", title: "跑 /usage",
              desc: "每次刷新后台跑一次 claude -p /usage 读取额度。零钥匙串，但会起一个短进程（略慢）。",
              recommended: false, needsKeychain: false),
        .init(source: "oauth", title: "联网 API",
              desc: "读取 Claude Code 保存的登录凭证，直接向 api.anthropic.com 查询。数据最全（含分模型限额），但要读系统钥匙串。",
              recommended: false, needsKeychain: true),
    ]

    static let qoderOption = Option(
        source: "", title: "联网查询账号额度",
        desc: "读取本机 Qoder 登录凭证，向 qoder.com 查账号额度。CLI 与 IDE 登录同一账号时共用一份；登录了不同账号时各行显示各自账号的额度。",
        recommended: false, needsKeychain: true)

    static let qwenWorkOption = Option(
        source: "", title: "缓存真实积分账单",
        desc: "读取本机千问办公登录凭证，向 qwenwork.cn 获取积分历史。usageBar 持久化最近一次成功结果，并按今日、本周、近 7 天、本月等周期汇总实际扣减；不会上传会话内容。",
        recommended: false, needsKeychain: true)

    private var selectedOption: Option {
        if isClaude { return Self.claudeOptions.first { $0.source == selected } ?? Self.claudeOptions[0] }
        return isQwenWork ? Self.qwenWorkOption : Self.qoderOption
    }

    private var headerTitle: String {
        if isClaude { return "开启 Claude Code 额度监测" }
        if isQwenWork { return "开启千问办公积分监测" }
        return "开启 Qoder 额度监测"
    }

    private var headerSubtitle: String {
        if isClaude { return "选一个获取额度的方式" }
        if isQwenWork { return "确认后开始联网同步积分历史" }
        return "确认后开始联网查询账号额度"
    }

    private var confirmTitle: String {
        selectedOption.needsKeychain ? "去授权并启用" : "启用"
    }
}
