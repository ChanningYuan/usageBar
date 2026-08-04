import SwiftUI
import usageBarCore

/// 详情页的「provider 声明表」——把原先散在三处的硬编码收进一张表：
///
/// | 原先 | 现在 |
/// |---|---|
/// | `ProviderDetailView.swift` 的 `metricGrid` / `openCodeMetricGrid` / `codexMetricGrid` 三个函数分叉 | `metricRows` 声明块清单，UI 照单渲染 |
/// | `UsageView.swift` 的手写白名单 `expandable: (pid == "claude-code" \|\| ...)` | `ProviderDetailRegistry.spec(for:) != nil` |
/// | `UsageViewModel.loadDetail` 的 `if providerId == "codex" … else …` 分派链 | `spec.scanner` |
/// | `accent` / `usesEquivalentCost` 的 `if providerId ==` 开关 | `accentDark/Light` / `costUnit` |
///
/// **加第 N 个 provider = 在 `specs` 里加一行声明，不碰 UI 代码。**
/// 方案：`_notes/docs/0713-Cursor计数修复与详情页扩展/详情页模块化-spec.md`

// MARK: - 金额口径（四档）

/// 详情页金额口径。**按「行（模型）」判定，不写死在 provider 上**（spec §1e）：
/// 1. 该行模型名能查到价 → `.equivalentUSD`
/// 2. 查不到价但有 credit → `.credits`
/// 3. 只有周期总账单、不能归因到行 → `.creditsTotalOnly`
/// 4. 都没有 → `.unavailable`
///
/// 这里的 `costUnit` 是 provider 的**默认档**；将来 BYOK（自带 key）时单行可按真实模型名升级到
/// `.equivalentUSD`，代码不用改结构。
enum CostUnit: Equatable {
    /// `≈ $12.3 等效` —— token × 价目表单价。模型名剥掉 thinking/fast 等尾段后能命中真身。
    case equivalentUSD
    /// `≈ 6.78 Credits` —— 直接读数据自带的 credit，**绕开价目表**（WorkBuddy）。
    /// ⚠️ credit 是整条消息的标量，**拆不到四列** → 指标区金额位显示 `—`。
    case credits
    /// 账户账单给出所选周期的**精确积分总额**，但没有 request/session/model 关联字段。
    /// Hero 展示精确积分；指标、模型、会话行统一显示 `—`，不猜摊（千问办公）。
    case creditsTotalOnly
    /// `—` —— 模型名被厂商打码（`qmodel`）且本地无任何 credit 字段（Qoder 全家桶）。
    case unavailable
}

// MARK: - 指标块

/// 一格指标的语义：决定图标 / 标签 / 从 `TokenBreakdown` 取哪个值 / 怎么算钱。
enum MetricKind {
    case input           // 净输入（不含缓存命中）
    case inputWithCache  // 输入（含缓存）= 净输入 + 缓存读 —— Codex 父块口径
    case output
    case cacheRead
    case cacheCreate
    case reasoning       // 思考（output 的子集，不计入 total）

    var icon: String {
        switch self {
        case .input, .inputWithCache: return "arrow.down"
        case .output: return "arrow.up"
        case .cacheRead: return "bolt.fill"
        case .cacheCreate: return "cylinder.split.1x2.fill"
        case .reasoning: return "brain"
        }
    }

    /// 独立格 / 父块顶部用的标签
    var tileLabel: String {
        switch self {
        case .input: return "净输入 (input)"
        case .inputWithCache: return "输入 (input)"
        case .output: return "输出 (output)"
        case .cacheRead: return "缓存读 (cache_read)"
        case .cacheCreate: return "缓存写 (cache_creation)"
        case .reasoning: return "思考 (reasoning)"
        }
    }

    /// 挂在父块下的子级行标签（语义是「⊂ 父块」，故措辞不同：缓存读 → 缓存输入）
    var childLabel: String {
        switch self {
        case .cacheRead: return "缓存输入 (cached)"
        case .reasoning: return "思考 (reasoning)"
        default: return tileLabel
        }
    }

    func value(_ t: TokenBreakdown) -> Int {
        switch self {
        case .input: return t.input
        case .inputWithCache: return t.input + t.cacheRead
        case .output: return t.output
        case .cacheRead: return t.cacheRead
        case .cacheCreate: return t.cacheCreate
        case .reasoning: return t.reasoning
        }
    }

    /// 逐模型用各自单价累加（混合模型时用单一价会失真）。与重构前三个 grid 函数的算法逐字等价。
    func cost(_ models: [ModelDetailRecord]) -> Double {
        switch self {
        case .input:
            return models.reduce(0.0) { $0 + Double($1.tokens.input) * UnifiedPricing.inputRate(for: $1.modelId) }
        case .inputWithCache:
            return models.reduce(0.0) {
                $0 + Double($1.tokens.input) * UnifiedPricing.inputRate(for: $1.modelId)
                   + Double($1.tokens.cacheRead) * UnifiedPricing.cacheReadRate(for: $1.modelId)
            }
        case .output:
            return models.reduce(0.0) { $0 + Double($1.tokens.output) * UnifiedPricing.outputRate(for: $1.modelId) }
        case .cacheRead:
            return models.reduce(0.0) { $0 + Double($1.tokens.cacheRead) * UnifiedPricing.cacheReadRate(for: $1.modelId) }
        case .cacheCreate:
            return models.reduce(0.0) {
                $0 + Double($1.tokens.cacheCreate5m) * UnifiedPricing.cacheWrite5mRate(for: $1.modelId)
                   + Double($1.tokens.cacheCreate1h) * UnifiedPricing.cacheWrite1hRate(for: $1.modelId)
            }
        case .reasoning:
            return models.reduce(0.0) { $0 + Double($1.tokens.reasoning) * UnifiedPricing.outputRate(for: $1.modelId) }
        }
    }
}

/// 指标区的一块：独立格，或「父块 ⊃ 子级行」（子集关系，如 输出 ⊃ 思考）。
enum MetricBlock {
    case tile(MetricKind)
    case parent(MetricKind, child: MetricKind)
}

// MARK: - 缓存命中环口径

enum RingMode {
    /// 缓存命中 / 总量（与主行一致）—— Claude 系
    case ofTotal
    /// 缓存命中 / 输入（= cached / (净输入 + cached)，prompt cache 命中率，语义更贴切）—— Codex 系
    case ofInput

    func rate(_ t: TokenBreakdown) -> Double {
        switch self {
        case .ofTotal:
            return t.hitRate
        case .ofInput:
            let fullInput = t.input + t.cacheRead
            return fullInput > 0 ? Double(t.cacheRead) / Double(fullInput) : 0
        }
    }
}

// MARK: - 扫描器

/// Claude 同构 transcript 的「源」：根目录 + 文件过滤。
///
/// 必须与对应 `UsageProvider` 的**主行扫描口径逐字一致**，否则详情页的分项之和对不上列表主行。
struct ClaudeTranscriptSource {
    let root: URL
    /// Cowork 的 transcript 藏在 `/.claude/projects/` 这个**隐藏目录**里，不开这个就一个文件都扫不到。
    let includeHidden: Bool
    /// 路径必须包含（Cowork：`/.claude/projects/` —— 排除同目录下无 usage 的 audit.jsonl）
    let requirePath: String?
    /// 路径不能包含（Cowork：`/subagents/` —— 与 `CoworkProvider` 主行口径一致）
    let excludePath: String?

    init(root: URL, includeHidden: Bool = false, requirePath: String? = nil, excludePath: String? = nil) {
        self.root = root
        self.includeHidden = includeHidden
        self.requirePath = requirePath
        self.excludePath = excludePath
    }
}

/// 明细扫描器的选择。`.claudeTranscript` 带「源」—— 重构前 `ClaudeDetailScanner` 的路径是**写死**的
/// `~/.claude/projects`、完全无视传进来的 providerId（Cowork 若放开 drill-in 会显示 Claude Code 的数据，
/// 白名单恰好挡住、bug 尚未暴露）。参数化后这个坑一并堵上。
enum DetailScannerKind {
    /// Claude 同构 transcript（`message.usage` + `sessionId` + `message.model`）。
    /// Claude Code / Cowork / **Qoder CLI** / **Qoder Work** 全部复用 —— 结构一模一样，只是根目录不同。
    case claudeTranscript(ClaudeTranscriptSource)
    /// Codex rollout（`payload.type=="token_count"` 的累计值 → 必须差分）。
    /// Codex / **悟空**（内置 codex 内核，落点在 `~/.real/**/kernel/codex/sessions/`）共用。
    case codexRollout(root: URL, requirePath: String?)
    case openCode
    case cursor
    case workBuddy
    case qoderIde
    case qwenWork
    /// 悟空：**双源合并**（旧 requests.jsonl 占 99.96% + 新 codex rollout）。见 `WukongDetailScanner`。
    case wukong
}

// MARK: - 声明

struct ProviderDetailSpec {
    /// 指标区：外层是行，内层是该行的块（自由组合）
    let metricRows: [[MetricBlock]]
    /// 是否有「按来源」区块（仅 Claude Code：官方直连 / 中转代理）
    let hasSources: Bool
    /// 是否有「按会话」区块。Cursor = false（本地 mirror 无 conversationId，拆不出会话）
    let hasSessions: Bool
    /// 是否在详情页顶部画「账号额度」模块。默认 true。
    ///
    /// 千问办公 = false：它的额度就是「剩余可用」一个数，主列表药丸已经显示过，详情页再画一遍是重复
    /// （0804 对焦拍板 4b）。⚠️ 别改回用 `RateLimitSettings.logicalKey` 返回 nil 来关——那会把
    /// 主列表药丸和设置页状态一起关掉（初版就是这么错的）。
    let hasQuotaModule: Bool
    let ring: RingMode
    let costUnit: CostUnit
    let accentDark: String
    let accentLight: String
    let scanner: DetailScannerKind

    init(metricRows: [[MetricBlock]], hasSources: Bool, hasSessions: Bool,
         hasQuotaModule: Bool = true, ring: RingMode, costUnit: CostUnit,
         accentDark: String, accentLight: String, scanner: DetailScannerKind) {
        self.metricRows = metricRows
        self.hasSources = hasSources
        self.hasSessions = hasSessions
        self.hasQuotaModule = hasQuotaModule
        self.ring = ring
        self.costUnit = costUnit
        self.accentDark = accentDark
        self.accentLight = accentLight
        self.scanner = scanner
    }

    func accent(_ scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? accentDark : accentLight)
    }

    /// 实心 accent 之上的文字色：**按 accent 亮度自动选深/白**。
    ///
    /// 详情页的「选中态」（周期切换器、用量/时间切换）是「实心 accent + 白字」。
    /// Cursor 的 accent 是银灰 `#C7C7CC`（浅色），白字直接糊成一片（Pencil 原型里实测过）。
    /// 亮度阈值取 0.6：#C7C7CC ≈ 0.78 → 深色文字；#E8794F ≈ 0.55、#34BE95 ≈ 0.6 以下 → 白字（维持原样）。
    func onAccent(_ scheme: ColorScheme) -> Color {
        Self.luminance(scheme == .dark ? accentDark : accentLight) > 0.6
            ? Color(hex: "#1D1D1F") : .white
    }

    /// 相对亮度（sRGB 加权近似，够用于选黑/白字）
    private static func luminance(_ hex: String) -> Double {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return 0 }
        s = ""
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

enum ProviderDetailRegistry {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Claude Code：`~/.claude/projects/**/*.jsonl`（含 subagents/）
    private static var claudeSource: ClaudeTranscriptSource {
        .init(root: home.appendingPathComponent(".claude/projects"))
    }

    /// Cowork：桌面 App 沙箱 home 下的 Claude Code 风格 transcript。
    /// 过滤口径与 `CoworkProvider.fetchDailyRecords()` **逐字一致**，否则明细之和对不上主行。
    private static var coworkSource: ClaudeTranscriptSource {
        .init(root: home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions"),
              includeHidden: true,              // transcript 藏在隐藏目录 /.claude/projects/ 里
              requirePath: "/.claude/projects/",  // 排除同目录下无 usage 的 audit.jsonl
              excludePath: "/subagents/")
    }

    /// Qoder CLI：`~/.qoder/projects/<encoded-cwd>/<sessionId>.jsonl`
    private static var qoderCliSource: ClaudeTranscriptSource {
        .init(root: home.appendingPathComponent(".qoder/projects"))
    }

    /// QoderWork：`~/.qoderwork/projects/<workspace>/<sessionId>.jsonl`（含 subagents/ 递归，与主行一致）
    private static var qoderWorkSource: ClaudeTranscriptSource {
        .init(root: home.appendingPathComponent(".qoderwork/projects"))
    }

    /// 悟空：内置 codex 内核的 rollout 落点（0.9.66+）
    private static var wukongRoot: URL { home.appendingPathComponent(".real") }

    /// Codex：`~/.codex/sessions`
    private static var codexRoot: URL { home.appendingPathComponent(".codex/sessions") }

    /// ⚠️ 强调色一律配深浅两档，**别直接用品牌色**——原始品牌色小字对比普遍不足
    /// （Cursor 品牌色是纯黑 #000000，深色主题下会直接隐形；Qoder 家族的墨绿/墨青偏暗，
    /// 且 Qoder CLI 的品牌色 #10A37F 与 Codex **完全相同**、会视觉撞车）。
    static let specs: [String: ProviderDetailSpec] = [
        // 独立格 ×4
        "claude-code": ProviderDetailSpec(
            metricRows: [[.tile(.input), .tile(.output)],
                         [.tile(.cacheRead), .tile(.cacheCreate)]],
            hasSources: true, hasSessions: true, ring: .ofTotal, costUnit: .equivalentUSD,
            accentDark: "#E8794F", accentLight: "#C85A2B",
            scanner: .claudeTranscript(claudeSource)),

        // Cowork：与 Claude Code 数据完全同构（message.usage 五列齐全、sessionId、真模型名），
        // 只是根目录不同 → 复用同一个扫描器。无「按来源」（Cowork 走 Anthropic 官方直连，无中转之分）。
        // 强调色比 Claude Code 更浅一档，避免同框难分辨（主列表图标已用更深的陶土底区分）。
        "cowork": ProviderDetailSpec(
            metricRows: [[.tile(.input), .tile(.output)],
                         [.tile(.cacheRead), .tile(.cacheCreate)]],
            hasSources: false, hasSessions: true, ring: .ofTotal, costUnit: .equivalentUSD,
            accentDark: "#D98A63", accentLight: "#A04A22",
            scanner: .claudeTranscript(coworkSource)),

        // 父块 ×2（输入 ⊃ 缓存输入、输出 ⊃ 思考）
        "codex": ProviderDetailSpec(
            metricRows: [[.parent(.inputWithCache, child: .cacheRead),
                          .parent(.output, child: .reasoning)]],
            hasSources: false, hasSessions: true, ring: .ofInput, costUnit: .equivalentUSD,
            accentDark: "#34BE95", accentLight: "#0C8163",
            scanner: .codexRollout(root: codexRoot, requirePath: nil)),

        // 混合：独立格 ×3 + 父块 ×1（输出 ⊃ 思考）
        "opencode": ProviderDetailSpec(
            metricRows: [[.tile(.input), .parent(.output, child: .reasoning)],
                         [.tile(.cacheRead), .tile(.cacheCreate)]],
            hasSources: false, hasSessions: true, ring: .ofTotal, costUnit: .equivalentUSD,
            accentDark: "#F59E0B", accentLight: "#B45309",
            scanner: .openCode),

        // Cursor：独立格 ×4，但**无「按会话」**——本地 mirror 里没有 conversationId 字段，拆不出会话。
        // 这是唯一一个会「整块缺席」的 provider，页面明显比别的短。详见 `CursorDetailScanner`。
        // 强调色：品牌色是纯黑 #000000，深色主题下会**直接隐形** → 改用其官方图标的银灰。
        // ⚠️ 银灰是浅色，选中态标签上的白字会糊 → `ProviderDetailView` 的 segmented 已按亮度自动配深色文字。
        "cursor": ProviderDetailSpec(
            metricRows: [[.tile(.input), .tile(.output)],
                         [.tile(.cacheRead), .tile(.cacheCreate)]],
            hasSources: false, hasSessions: false, ring: .ofTotal, costUnit: .equivalentUSD,
            accentDark: "#C7C7CC", accentLight: "#4A4A4F",
            scanner: .cursor),

        // ── Qoder 全家桶：模型名被厂商打码成 qmodel / qwork-auto，价目表永远查不到 → 金额位 `—`。
        //    强调色整体走青蓝系，与 Codex 的绿彻底拉开（Qoder CLI 的原始品牌色 #10A37F 与 Codex 完全相同）。

        // Qoder CLI：Claude 同款 transcript，复用 Claude 扫描器。
        // **3 格**（无缓存写）—— 2026-07-13 另一台机器实测：168 个文件、cache_creation 合计恒 0，
        // 与 Qoder Work / IDE 一致。（原按 4 格写，探针回来后改。数据见 `探针实测-悟空与QoderCLI.json`）
        // 金额「无价目」：它的 9 个「模型名」逐个查价目表 8 个查不到 ——
        // `ultimate` / `efficient` / `lite` / `performance` 是**套餐档位名**不是模型；
        // `dmodel` / `kmodel` / `gm51model` / `qmodel_latest` 是打码别名；`auto` 是路由名（已进黑名单）。
        // ⚠️ token 真值受环境变量 QODER_EXPOSE_TOKEN_USAGE 控制，没开时四列全 0（详情页会是空态）。
        "qoder-cli": ProviderDetailSpec(
            metricRows: [[.tile(.input), .tile(.output)],
                         [.tile(.cacheRead)]],
            hasSources: false, hasSessions: true, ring: .ofTotal, costUnit: .unavailable,
            accentDark: "#35C2B1", accentLight: "#0C7A6E",
            scanner: .claudeTranscript(qoderCliSource)),

        // Qoder Work：同上，但实测缓存写恒 0（协议不暴露）→ 只声明 3 块，UI 就只渲染 3 块。
        // 这正是「清单驱动」的价值：少一列不需要写新函数。
        "qoder-work": ProviderDetailSpec(
            metricRows: [[.tile(.input), .tile(.output)],
                         [.tile(.cacheRead)]],
            hasSources: false, hasSessions: true, ring: .ofTotal, costUnit: .unavailable,
            accentDark: "#29B5A8", accentLight: "#0C6B52",
            scanner: .claudeTranscript(qoderWorkSource)),

        // Qoder IDE：唯一一个数据源是 SQLite 的 provider。协议无缓存写 → 3 块。
        "qoder-ide": ProviderDetailSpec(
            metricRows: [[.tile(.input), .tile(.output)],
                         [.tile(.cacheRead)]],
            hasSources: false, hasSessions: true, ring: .ofTotal, costUnit: .unavailable,
            accentDark: "#35A8CE", accentLight: "#0B5266",
            scanner: .qoderIde),

        // 千问办公：OpenAI usage 暴露 prompt/output/cache read；prompt 已包含 cached，parser 先做差得到净输入。
        // 当前转换器不提供缓存写 → 3 块。积分总额来自账户账单，但账单无 request/session/model id，
        // 因此只在 Hero 展示所选周期精确积分，绝不猜摊到下面各行。
        "qwen-work": ProviderDetailSpec(
            // 4 块而不是 3 块：日志里 `cache_creation_input_tokens` **字段是存在的**，
            // 只是厂商目前没往里填（2026-08-04 全量扫描恒 0）。解析器读的是真值，
            // 所以这里也照四列摊开——「总量 = 四块之和」这个不变量才永远成立，
            // 厂商哪天开始填也不用再改稿改码。
            // （对比 WorkBuddy：那是协议里**根本没有**缓存写字段，所以它只有 3 块。）
            metricRows: [[.tile(.input), .tile(.output)],
                         [.tile(.cacheRead), .tile(.cacheCreate)]],
            hasSources: false, hasSessions: true, hasQuotaModule: false,
            ring: .ofTotal, costUnit: .creditsTotalOnly,
            accentDark: "#45E59A", accentLight: "#147A52",
            scanner: .qwenWork),

        // WorkBuddy：净输入 + 输出⊃思考 + 缓存读。**无缓存写**（prompt_tokens 已含缓存，主行口径如此）。
        // 金额走「信用点」——模型名是 auto（打码），等效美元算不出来，但数据自带 rawUsage.credit。
        // ⚠️ credit 是整条消息的标量、拆不到四列 → 指标区金额位显示 `—`，只有总额/按模型/按会话有 Credits。
        "workbuddy": ProviderDetailSpec(
            metricRows: [[.tile(.input), .parent(.output, child: .reasoning)],
                         [.tile(.cacheRead)]],
            hasSources: false, hasSessions: true, ring: .ofTotal, costUnit: .credits,
            accentDark: "#8A8AE8", accentLight: "#4A4AC0",
            scanner: .workBuddy),

        // 悟空：**双源合并**（`WukongDetailScanner`）。指标区沿用 Codex 的父块形态（新源是 codex 同款）。
        // ⚠️ 2026-07-13 探针推翻了原假设：旧源 `requests.jsonl` 有 3.52 亿 token（**占 99.96%**），
        //    新源 rollout 只有 14.9 万（0.04%）。只做新源的话详情页会显示 14.9 万、主行显示 3.52 亿 —— 崩坏。
        //    而旧源**完全拆得开**（有 model 真名 + sessionId）→ 必须合并，拍板 4b 的前提不成立。
        // 金额「等效美元」：两源的模型名多为真名（gpt-5.5 / claude-opus-4-7 / deepseek-v4-flash 都查得到价）；
        //    dingtalk-* 这类查不到的会走「无价目」按钮，逐行诚实展示。
        "wukong": ProviderDetailSpec(
            metricRows: [[.parent(.inputWithCache, child: .cacheRead),
                          .parent(.output, child: .reasoning)]],
            hasSources: false, hasSessions: true, ring: .ofInput, costUnit: .equivalentUSD,
            accentDark: "#4C9AFF", accentLight: "#0D5FCC",
            scanner: .wukong),
    ]

    static func spec(for providerId: String) -> ProviderDetailSpec? { specs[providerId] }

    /// 详情页门禁：有声明才能 drill-in。取代 `UsageView` 里的手写白名单。
    static func isDrillable(_ providerId: String) -> Bool { specs[providerId] != nil }
}
