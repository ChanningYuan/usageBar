import Foundation
import usageBarCore

/// Codex 账号额度读取（v0.3.24 单桶，v0.3.29 起多桶）——纯本地，零联网、零成本。
///
/// 数据源：`~/.codex/sessions/**/rollout-*.jsonl` 里 `payload.type=="token_count"` 事件的 `rate_limits` 字段。
///
/// ⚠️ 窗口结构是动态的（2026-07-14 探针实证，见 spec §1c）：
/// ```json
/// "rate_limits":{"primary":{"used_percent":21,"window_minutes":10080,"resets_at":...},"secondary":null,...}
/// ```
/// primary 可能是 5 小时窗也可能是 7 天窗（看 `window_minutes`），secondary 可能为 null。
/// **按 window_minutes 推导 label，有几个窗口画几个，别写死 5h+7d。**
///
/// ⚠️ 额度不再是账号级单桶（2026-08-03 上游变更，issue #6）：OpenAI 给部分新模型
/// （如 GPT-5.3-Codex-Spark）配了**独立限额池**，与主套餐池互相独立、结构同形。
/// 若仍按「全局最后一条」取，最近会话都是 Spark 时，主套餐真实用量会被 Spark 池的 0% 整个盖掉。
///
/// ⚠️ 池的**身份标识一直在漂**（两代格式都要兼容，2026-08-11 本机实测）：
/// - cli 0.146：`limit_id` 可区分（"codex" vs "codex_bengalfox"），`limit_name` 带模型名；
/// - cli 0.147 起：`limit_id` **恒为 "codex"、`limit_name` 恒 null**——本地只剩两条线索：
///   同一时刻的 `resets_at` 相同 = 同一个**窗口实例**；哪些**模型**的会话在写哪个实例。
///
/// 于是聚合分两层（`bucketize`）：
/// 1. 条目按 `limit_id|resets_at` 归成**实例**（每实例留行级时间戳最新的一条）；
/// 2. 实例并成**池**：0.146 按 limit_id 并；0.147 按「模型共现」并——专属池只被自己的模型写，
///    主池被其余模型混写。**同池只显示最新实例**：主池手动重置/滚动后 `resets_at` 会跳变，
///    被顶替的旧实例即使时间上没过期也是死数据（实测 08-15/08-17/08-18 三代并存）。
/// ⚠️ 条目一律用**行级时间戳**（envelope `timestamp`）排新旧——长期复用的会话文件 mtime 是今天、
/// 里面却存着几周前的旧条目，按文件 mtime 排会翻车。
/// 主池保持 `7d x%` chip 样式；专属池用 limit_name/会话模型短名当 label（类比 Claude 的
/// 分模型 Fable chip，复用 `scopeModel`）。
public struct CodexRateLimitReader {
    public init() {}

    private var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    public static let providerId = "codex"

    public func read(now: Date = Date()) -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: Self.providerId, windows: [], capturedAt: now, error: e)
        }

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return fail(.noDataSource)
        }
        // 取 mtime 最新的 rollout 文件（额度是账号级全局状态，只要最新一条）
        let files = JSONLReader.findFiles(under: sessionsDir) { url in
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        }
        let sorted = files.compactMap { url -> (URL, Date)? in
            guard let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return nil }
            return (url, m)
        }.sorted { $0.1 > $1.1 }

        guard !sorted.isEmpty else { return fail(.noDataSource) }

        // 扫描范围：最新 5 个文件（旧覆盖底线）+ 7 天内（最大窗口长度）的其余文件，上限 50 个。
        // 只扫前 5 个不够——主模型与 Spark 混用时，旧桶的最新快照可能不在前 5 个文件里（issue #6）。
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        var scan = Array(sorted.prefix(5))
        for f in sorted.dropFirst(5) where f.1 >= cutoff { scan.append(f) }
        scan = Array(scan.prefix(50))

        var entries: [RLEntry] = []
        var recentHasData = false   // 前 5 个文件里有没有 rate_limits（纯 API Key 登录可能没有）
        for (idx, file) in scan.enumerated() {
            let found = rateLimitsEntries(in: file.0, mtime: file.1, fileIndex: idx)
            if idx < 5 && !found.isEmpty { recentHasData = true }
            entries.append(contentsOf: found)
        }
        // 近期文件全无 rate_limits 字段 → 纯 API Key 登录，无额度概念（别拿更老文件里的过期桶充数）
        guard !entries.isEmpty, recentHasData else { return fail(.noQuotaData) }
        let (windows, plan) = Self.bucketize(entries, now: now)
        guard !windows.isEmpty else { return fail(.noQuotaData) }
        return RateLimitSnapshot(providerId: Self.providerId, windows: windows,
                                 planType: plan, capturedAt: now, error: nil)
    }

    /// 单条 rate_limits 证据：原始字段 + 行级时间戳 + 会话当时的模型 + 来源文件序号（0=最新）。
    struct RLEntry {
        let rl: [String: Any]
        let ts: Date
        let model: String?
        let file: Int
        init(rl: [String: Any], ts: Date, model: String? = nil, file: Int = 0) {
            self.rl = rl; self.ts = ts; self.model = model; self.file = file
        }
    }

    /// envelope `timestamp`（`2026-08-11T13:26:35.208Z`）解析；带/不带毫秒都收。
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
    static func parseTs(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    /// 收集一个文件里的 `rate_limits` 事件（读尾部 256KB，不整份 parse）。
    /// 正序扫描、让「当前模型」跟着行走——每条事件标上此刻会话用的模型（0.147 格式并池/命名靠它）；
    /// 模型名可能只在文件开头的 session_meta 里（尾部窗口够不到）→ 头部 64KB 兜底。
    /// 时间戳取行级 envelope `timestamp`（解析失败退回文件 mtime）。同文件内每实例只留最后一条。
    private func rateLimitsEntries(in url: URL, mtime: Date, fileIndex: Int) -> [RLEntry] {
        guard let tail = Self.readTail(url, maxBytes: 256 * 1024) else { return [] }
        var model: String? = Self.firstModel(in: Self.readHead(url, maxBytes: 64 * 1024))
        var byKey: [String: RLEntry] = [:]
        var order: [String] = []
        for line in tail.split(separator: "\n") {
            guard line.contains("\"model\"") || line.contains("rate_limits"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            if let m = payload["model"] as? String, !m.isEmpty { model = m }
            guard payload["type"] as? String == "token_count",
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            let key = Self.bucketKey(rl)
            let ts = Self.parseTs(obj["timestamp"] as? String) ?? mtime
            if byKey[key] == nil { order.append(key) }
            byKey[key] = RLEntry(rl: rl, ts: ts, model: model, file: fileIndex)  // 文件内按时序，后写的更新
        }
        return order.compactMap { byKey[$0] }
    }

    /// 头部文本里第一个 `model` 字段（session_meta / turn_context 均可）。
    static func firstModel(in text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"model\"") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            if let m = payload["model"] as? String, !m.isEmpty { return m }
            if let meta = payload["session_meta"] as? [String: Any],
               let m = meta["model"] as? String, !m.isEmpty { return m }
        }
        return nil
    }

    /// 主套餐桶的 limit_id；旧格式（无 limit_id 字段）也归入主桶 id，向后兼容。
    static let mainBucketId = "codex"

    /// 桶身份 key：0.146 格式靠 `limit_id` 区分；0.147 起 limit_id 恒 "codex" → 叠加 `primary.resets_at`
    /// 区分窗口实例（同池同窗口的 resets_at 精确相同；不同池各自从首次使用起独立计时）。
    static func bucketKey(_ rl: [String: Any]) -> String {
        let id = (rl["limit_id"] as? String) ?? mainBucketId
        let p = rl["primary"] as? [String: Any]
        let resets = (p?["resets_at"] as? NSNumber)?.intValue ?? -1
        return "\(id)|\(resets)"
    }

    /// 多池聚合（issue #6）。两层：条目 → 窗口实例（`limit_id|resets_at`）→ 池。详见文件头注释。
    ///
    /// 过期池剔除：当前实例的 `resets_at` 已过 = 窗口已结束，百分比失效 → 丢弃；无 `resets_at` 时
    /// 按「行级时间超过自身窗口长度」判过期。全过期则退回最近写过的一池（对齐旧行为：长期没用
    /// Codex 也显示最后已知状态，而不是整行消失）。
    static func bucketize(_ entries: [RLEntry],
                          now: Date) -> (windows: [RateLimitWindow], plan: String?) {
        guard !entries.isEmpty else { return ([], nil) }

        // 1. 条目归并成窗口实例：每实例留 ts 最新的一条，累积「哪些模型写过 / 出现在几个文件」
        struct Instance {
            var newest: RLEntry
            var models: Set<String> = []
            var files: Set<Int> = []
            var limitId: String
        }
        var inst: [String: Instance] = [:]
        var order: [String] = []
        for e in entries {
            let key = bucketKey(e.rl)
            if inst[key] == nil {
                inst[key] = Instance(newest: e, limitId: (e.rl["limit_id"] as? String) ?? mainBucketId)
                order.append(key)
            } else if e.ts > inst[key]!.newest.ts {
                inst[key]!.newest = e
            }
            if let m = e.model { inst[key]!.models.insert(m) }
            inst[key]!.files.insert(e.file)
        }

        // 2. 实例并池：0.146（数据里有 ≥2 个不同 limit_id）按 limit_id 并；
        //    0.147（limit_id 恒同）按模型共现并——专属池只被自己的模型写，主池被其余模型混写。
        var poolKeys: [[String]] = []
        if Set(order.map { inst[$0]!.limitId }).count > 1 {
            var byId: [String: [String]] = [:]
            for k in order { byId[inst[k]!.limitId, default: []].append(k) }
            var seen = Set<String>()
            for k in order where seen.insert(inst[k]!.limitId).inserted {
                poolKeys.append(byId[inst[k]!.limitId]!)
            }
        } else {
            var groups: [(keys: [String], models: Set<String>)] = []
            var orphans: [String] = []   // 没抓到模型名的实例，最后并入文件覆盖最广的池
            for k in order {
                let ms = inst[k]!.models
                if ms.isEmpty { orphans.append(k) } else { groups.append(([k], ms)) }
            }
            var mergedAny = true
            while mergedAny {
                mergedAny = false
                outer: for i in groups.indices {
                    for j in groups.indices where j > i {
                        if !groups[i].models.isDisjoint(with: groups[j].models) {
                            groups[i].keys += groups[j].keys
                            groups[i].models.formUnion(groups[j].models)
                            groups.remove(at: j)
                            mergedAny = true
                            break outer
                        }
                    }
                }
            }
            poolKeys = groups.map(\.keys)
            if !orphans.isEmpty {
                func fileSpan(_ keys: [String]) -> Int {
                    keys.reduce(into: Set<Int>()) { $0.formUnion(inst[$1]!.files) }.count
                }
                if let idx = poolKeys.indices.max(by: { fileSpan(poolKeys[$0]) < fileSpan(poolKeys[$1]) }) {
                    poolKeys[idx] += orphans
                } else {
                    poolKeys = [orphans]
                }
            }
        }

        // 3. 每池取「当前实例」= 最新条目 ts 最大的那个。旧实例是被顶替的历史窗口——主池手动重置/
        //    滚动后 resets_at 会跳变，旧实例即使时间上没过期也是死数据，绝不展示。
        struct Pool {
            let current: Instance
            let models: Set<String>
            let files: Set<Int>
            let latestTs: Date
        }
        var pools: [Pool] = poolKeys.map { keys in
            let insts = keys.map { inst[$0]! }
            let cur = insts.max { $0.newest.ts < $1.newest.ts }!
            return Pool(current: cur,
                        models: insts.reduce(into: Set<String>()) { $0.formUnion($1.models) },
                        files: insts.reduce(into: Set<Int>()) { $0.formUnion($1.files) },
                        latestTs: cur.newest.ts)
        }

        // 4. 过期池剔除；全过期退回最近写过的一池
        func isFresh(_ p: Pool) -> Bool {
            let pr = p.current.newest.rl["primary"] as? [String: Any]
            if let resets = (pr?["resets_at"] as? NSNumber)?.doubleValue {
                return Date(timeIntervalSince1970: resets) > now
            }
            if let m = (pr?["window_minutes"] as? NSNumber)?.intValue {
                return now.timeIntervalSince(p.latestTs) <= Double(m) * 60
            }
            return true
        }
        var alive = pools.filter(isFresh)
        if alive.isEmpty, let last = pools.max(by: { $0.latestTs < $1.latestTs }) { alive = [last] }

        // 5. 主池挑选：只有「无名池」有资格（有 limit_name 的是 0.146 专属池；全是具名池就没有主池，
        //    全部按 scoped 呈现）。多个无名池并存时：limit_id=="codex" 优先 → 跨 ≥2 模型的必是共享
        //    主池（专属池按构造只被一个模型写）→ 出现文件多的（主池几乎每个会话都在写）→ 最近写过的。
        let candidates = alive.indices.filter { (alive[$0].current.newest.rl["limit_name"] as? String) == nil }
        let mainIdx: Int? = candidates.count == 1 ? candidates.first : candidates.min { a, b in
            let A = alive[a], B = alive[b]
            let ia = A.current.limitId == mainBucketId, ib = B.current.limitId == mainBucketId
            if ia != ib { return ia }
            let ma = A.models.count >= 2, mb = B.models.count >= 2
            if ma != mb { return ma }
            if A.files.count != B.files.count { return A.files.count > B.files.count }
            return A.latestTs > B.latestTs
        }
        if let m = mainIdx, m != 0 { alive.swapAt(0, m) }
        let hasMain = mainIdx != nil

        // plan_type 是账号级的（部分条目里是 null）：按行级时间新→旧找第一个非空的（过期条目也算）
        let plan = entries.sorted { $0.ts > $1.ts }.compactMap { $0.rl["plan_type"] as? String }.first

        var windows: [RateLimitWindow] = []
        for (i, p) in alive.enumerated() {
            let e = p.current.newest
            let base = parseWindows(e.rl)
            if i == 0 && hasMain {
                windows.append(contentsOf: base)
            } else {
                // 专属池：limit_name（0.146）→ 会话模型（0.147）取短名当 label；
                // 单窗口时不带 5h/7d（类比 Claude 的 Fable chip）。kind 用 scoped 前缀 + scopeModel
                // 区分历史池（别把 resets 编进 kind——每个窗口实例都会另起一池）。
                let short = ((e.rl["limit_name"] as? String).map(Self.nameShort)
                             ?? p.models.sorted().first.map(Self.nameShort)) ?? "限额"
                windows.append(contentsOf: base.map { w in
                    RateLimitWindow(kind: w.kind.replacingOccurrences(of: "codex", with: "codex_scoped"),
                                    label: base.count > 1 ? "\(short) \(w.label)" : short,
                                    windowMinutes: w.windowMinutes, usedPercent: w.usedPercent,
                                    resetsAt: w.resetsAt, severity: w.severity, scopeModel: short)
                })
            }
        }
        return (windows, plan)
    }

    /// 展示短名：取 `-` 分隔的最后一段并首字母大写（"GPT-5.3-Codex-Spark" / "gpt-5.3-codex-spark" → "Spark"）。
    static func nameShort(_ name: String) -> String {
        guard let last = name.split(separator: "-").last, !last.isEmpty else { return name }
        return String(last).prefix(1).uppercased() + String(last).dropFirst()
    }

    /// primary / secondary 各自按 window_minutes 推导，null 的跳过。
    static func parseWindows(_ rl: [String: Any]) -> [RateLimitWindow] {
        var out: [RateLimitWindow] = []
        for (key, kind) in [("primary", "codex_primary"), ("secondary", "codex_secondary")] {
            guard let w = rl[key] as? [String: Any],
                  let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let label = minutes.map { RateLimitWindow.label(forWindowMinutes: $0) } ?? key
            out.append(RateLimitWindow(kind: kind, label: label, windowMinutes: minutes,
                                       usedPercent: pct, resetsAt: resets))
        }
        return out
    }

    /// 读文件头部最多 maxBytes 字节（`String(decoding:)` 对截断处的半个多字节字符做替换而非失败）
    static func readHead(_ url: URL, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 读文件尾部最多 maxBytes 字节（macOS 无 tac，用 FileHandle seek）
    static func readTail(_ url: URL, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
