import Foundation

/// Codex 累计计数器的「谱系」差分核心（v0.3.39）。
///
/// 输入：一个 rollout 文件里按序收集的 `token_count` 事件——每条带会话累计 `total_token_usage`，
/// 以及（0.142 起可靠的）单次请求增量 `last_token_usage`；输出：每条事件的**真实增量**（四维）。
/// 主行 `CodexProvider` 与详情 `CodexDetailScanner` 共用这一份状态机，保证「列表总量 = 详情合计」。
///
/// ── 五条规则（全部有本机日志实证，调研见 `_notes/docs/0916-Codex统计口径调研/Codex统计口径调研.md`）──
///  1. **峰值门**：累计值没超过当前谱系峰值的事件不计（fork 的 replay 段 / 重复落盘的同一事件）。
///  2. **单次增量**：拿得到 `last_token_usage` 时，增量 = min(last, 累计值增幅)。0.142 起两者逐文件
///     完全一致（本机 141 个文件对拍零偏差）；<0.142 的 last 会虚高 8–99%，取 min 兜住。
///     → 不变量：在单调、无快照、无重启的数据上，结果与旧口径「差分 + 峰值跟踪」逐事件相等，
///       新口径**永远不高于**旧口径，只在计数器重启场景把漏计补回来。
///  3. **继承快照**：`last` 全 0 而累计值 > 0 = 子代理（guardian / thread_spawn）文件首条继承的父会话
///     快照，只抬峰值、不计增量。旧口径按「子代理基线 0」把它整段算成新增：本机 7/28 一个 thread_spawn
///     多算 1.03 亿、7/26 一个 guardian 多算 2716 万（ccusage #950 报 91 倍、CodexBar #3524 报 30–150 倍同病）。
///     ⚠️ 不能用 `session_meta.subagent_history_start_ordinal` 当排除边界（CodexBar 0.58.0 的做法）：本机
///     30 个子代理文件该值全等于文件末行，按它算会把 guardian 自己的真实请求（1.43 亿）全判成继承而清零；
///     实测这些请求在父文件里**没有**重复记账，是真实、独立计费的用量。
///  4. **计数器重启**：累计值比上一条**小**、且恰好等于本条 `last`（= 新谱系的第一条请求）→ Codex 0.153 起
///     续聊老会话时计数器从 0 重数（本机 7/26 会话 9/12 从 2.497 亿掉到 68,126，Codex 自己的
///     `state_5.sqlite` 也只剩续聊后的量）。峰值归零、从头计。不加这条，续聊后所有用量都被峰值门吃掉
///     （本机 9/12 一天 407 万记成 0；CodexBar #3510 同病、至今 closed as not planned）。
///  5. **乱序 / 陈旧**：累计值变小但不满足规则 4 → 跳过本条、不动任何状态（对应 CodexBar PR #3120 的
///     stale-regression 检测）。旧口径在这里靠峰值跟踪，行为一致。
///
/// 事件按 (时间戳, 文件顺序) 稳定排序：replay 段全落在同一秒，不稳定排序会把单调序列打乱成假回落。
public struct CodexUsage: Sendable, Equatable {
    public var input: Int       // input_tokens（含 cached）
    public var cached: Int      // cached_input_tokens（input 子集）
    public var output: Int      // output_tokens（含 reasoning）
    public var reasoning: Int   // reasoning_output_tokens（output 子集）

    public init(input: Int = 0, cached: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.input = input; self.cached = cached; self.output = output; self.reasoning = reasoning
    }

    public static let zero = CodexUsage()

    /// 计量口径（与 `CodexProvider.eventTotal` 同）：input（含 cached）+ output（含 reasoning）。
    public var total: Int { input + output }

    func componentMax(_ o: CodexUsage) -> CodexUsage {
        CodexUsage(input: max(input, o.input), cached: max(cached, o.cached),
                   output: max(output, o.output), reasoning: max(reasoning, o.reasoning))
    }
}

/// 一条 `token_count` 事件（解析后）。`last == nil` = 日志里没有 `last_token_usage`（未知旧格式）。
public struct CodexTokenEvent: Sendable {
    public let ts: Date
    public let total: CodexUsage
    public let last: CodexUsage?
    public let model: String

    public init(ts: Date, total: CodexUsage, last: CodexUsage?, model: String = "") {
        self.ts = ts; self.total = total; self.last = last; self.model = model
    }
}

/// 一条真实增量（只对「计入」的事件产出）。
public struct CodexDeltaEvent: Sendable, Equatable {
    public let ts: Date
    public let delta: CodexUsage
    public let model: String
}

public enum CodexLineage {
    public struct Result: Sendable {
        public let deltas: [CodexDeltaEvent]
        /// 全文件**历史最大**累计值（含基线）。fork 的差分基线用它——计数器重启后**不回落**：
        /// 用回落后的小值当基线，会把「重启前建的 fork」整段 replay 当新增（本机场景 = 2.5 亿级虚高）；
        /// 用历史最大值最多让 fork 自己的新增被少算（保守方向）。
        public let maxTotal: CodexUsage
    }

    public static func deltas(events: [CodexTokenEvent], baseline: CodexUsage) -> Result {
        let sorted = events.enumerated().sorted { a, b in
            a.element.ts != b.element.ts ? a.element.ts < b.element.ts : a.offset < b.offset
        }.map(\.element)

        var peakC = baseline              // 各分量峰值（差分模式用）
        var peakTotal = baseline.total    // 当前谱系峰值（峰值门）
        var maxTotal = baseline           // 历史最大（fork 基线）
        var prevTotal: Int? = nil         // 上一条（未被跳过的）累计值
        var out: [CodexDeltaEvent] = []

        for ev in sorted {
            let tot = ev.total
            // Codex Desktop「从其他 AI 应用导入」的 replay 快照：细分全 0 → 完全无视（v0.3.20 口径）。
            guard tot.total > 0 else { continue }
            maxTotal = maxTotal.componentMax(tot)

            // 规则 3：继承快照（last 全 0）——只抬峰值。
            if let last = ev.last, last.total == 0 {
                peakC = peakC.componentMax(tot)
                peakTotal = max(peakTotal, tot.total)
                prevTotal = tot.total
                continue
            }
            // 规则 4 / 5：累计值回落。
            if let p = prevTotal, tot.total < p {
                if let last = ev.last, last.total == tot.total {
                    peakC = .zero; peakTotal = 0          // 计数器重启 → 新谱系
                } else {
                    continue                              // 乱序 / 陈旧 → 跳过
                }
            }
            prevTotal = tot.total

            // 规则 1：峰值门。
            if tot.total > peakTotal {
                let advance = tot.total - peakTotal
                var d: CodexUsage
                if let last = ev.last, last.total > 0, last.total <= advance {
                    d = last                                                  // 规则 2
                } else {
                    d = CodexUsage(input: max(0, tot.input - peakC.input),
                                   cached: max(0, tot.cached - peakC.cached),
                                   output: max(0, tot.output - peakC.output),
                                   reasoning: max(0, tot.reasoning - peakC.reasoning))
                }
                d.cached = min(d.cached, d.input)          // 缓存命中 ≤ 输入（浅色段不超总长）
                d.reasoning = min(d.reasoning, d.output)   // 思考 ≤ 输出
                out.append(CodexDeltaEvent(ts: ev.ts, delta: d, model: ev.model))
                peakTotal = tot.total
            }
            peakC = peakC.componentMax(tot)
        }
        return Result(deltas: out, maxTotal: maxTotal)
    }
}
