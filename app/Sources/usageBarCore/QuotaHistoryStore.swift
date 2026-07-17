import Foundation

/// 账号额度历史（v0.3.26）——「变化即记」的追加式流水，覆盖**所有** provider 的额度池。
///
/// 现有 `RateLimitStore` 只存**最新一份**快照（后写覆盖前写），历史全丢，没法做消耗分析。
/// 本 store 在额度采集成功后按 (provider, pool, model) 对比上一条，变了才追加一行：
/// - **信用点池**（Qoder / WorkBuddy，有原始点数）：对比 `used` / `total`，行里记这两个数
/// - **百分比池**（Claude / Codex / Cursor，官方只给百分比）：对比 `usedPercent`，行里记它
///
/// `plan` / `resetsAt` 只随行携带（分析时定位周期用），**不参与触发判断**——月度池的
/// resetsAt 是本周期固定截止日，周期翻篇时 used 回落本身就会触发写入；Claude 滚动窗的
/// resetsAt 随时间漂移，拿它触发会每次都写（0717 定稿）。
///
/// 落盘 `quota-history.jsonl`（每行一条 JSON，追加不删改），与 rate-limit-snapshot.json 同目录。
/// 两类行示例：
/// `{"ts":"2026-07-17T14:30:12+08:00","provider":"qoder","pool":"monthly","plan":"teams",`
/// `"used":1850,"total":5000,"resetsAt":"2026-08-05T00:00:00+08:00"}`
/// `{"ts":"2026-07-17T14:30:12+08:00","provider":"claude-code","pool":"seven_day_opus",`
/// `"model":"Opus","plan":"max","usedPercent":12,"resetsAt":"2026-07-21T08:00:00+08:00"}`
///
/// ⚠️ 调用方约定（见 `RateLimitCoordinator.store`）：
/// - Qoder 快照会复制成 CLI/Work/IDE 三份，必须在复制**前**、以账号级 id（"qoder"）记一次。
/// - 采集失败（error != nil）不记——失败快照的 windows 可能是空/陈旧的。
public actor QuotaHistoryStore {
    public static let shared = QuotaHistoryStore()

    /// 磁盘一行的结构（字段含义见类注释的示例行）。
    /// 信用点池填 used/total、usedPercent 省略（可算）；百分比池只有 usedPercent。
    private struct Line: Codable {
        let ts: String
        let provider: String
        let pool: String
        let model: String?
        let plan: String?
        let used: Double?
        let total: Double?
        let usedPercent: Double?
        let resetsAt: String?
    }

    /// 变化判断的"上一条"状态（两类池共用：信用点池看 used/total，百分比池看 percent）
    private struct LastState: Equatable {
        let used: Double?
        let total: Double?
        let percent: Double?
    }

    private let fileURL: URL
    /// (provider|pool|model) → 上一条状态
    private var lastByKey: [String: LastState] = [:]
    private var seeded = false

    /// 默认路径：与 RateLimitStore 的 rate-limit-snapshot.json 同目录
    /// （`RateLimitStore.diskPath` 是 @MainActor 隔离的，这里不能引用，路径自建同款）。
    public static var defaultPath: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("usageBar", isDirectory: true)
            .appendingPathComponent("quota-history.jsonl")
    }

    public init(fileURL: URL = QuotaHistoryStore.defaultPath) {
        self.fileURL = fileURL
    }

    /// 采集成功后调用：快照里每个额度池与上一条对比，变了就追加一行。
    /// `provider` 用逻辑 id（"qoder" / "workbuddy" / "claude-code"…），别用复制后的实例 id。
    public func record(provider: String, snapshot: RateLimitSnapshot) {
        guard snapshot.error == nil else { return }
        seedIfNeeded()

        for w in snapshot.windows {
            let isCredits = (w.used != nil && w.total != nil)
            // 百分比圆整到 2 位：去浮点精度尾巴（14.000000000000002），也避免噪音触发假写入。
            // 判变和落盘用同一个圆整值，否则重启 seed 读回的值对不上、每次重启白写一行。
            let state = LastState(used: isCredits ? w.used : nil,
                                  total: isCredits ? w.total : nil,
                                  percent: isCredits ? nil : (w.usedPercent * 100).rounded() / 100)
            let key = "\(provider)|\(w.kind)|\(w.scopeModel ?? "")"
            if lastByKey[key] == state { continue }

            let line = Line(ts: Self.iso(snapshot.capturedAt),
                            provider: provider,
                            pool: w.kind,
                            model: w.scopeModel,
                            plan: snapshot.planType,
                            used: state.used,
                            total: state.total,
                            usedPercent: state.percent,
                            resetsAt: w.resetsAt.map(Self.iso))
            if append(line) {
                lastByKey[key] = state
            }
        }
    }

    // MARK: - 内部

    /// 首次使用时通读一遍存量文件，恢复各池"上一条"——否则每次 app 重启都会重复写一行。
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        try? JSONLReader.forEachLine(at: fileURL) { obj in
            guard let provider = obj["provider"] as? String,
                  let pool = obj["pool"] as? String else { return }
            let model = (obj["model"] as? String) ?? ""
            let state = LastState(used: (obj["used"] as? NSNumber)?.doubleValue,
                                  total: (obj["total"] as? NSNumber)?.doubleValue,
                                  percent: (obj["usedPercent"] as? NSNumber)?.doubleValue)
            self.lastByKey["\(provider)|\(pool)|\(model)"] = state   // 后写覆盖前写 = 天然取最后一条
        }
    }

    /// 追加一行；写失败（磁盘满等）返回 false 且不更新内存态，下次刷新自然重试。
    private func append(_ line: Line) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // 字段序稳定，便于肉眼 diff
        guard let data = try? enc.encode(line) else { return false }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            guard fm.createFile(atPath: fileURL.path, contents: nil) else { return false }
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
            return true
        } catch {
            return false
        }
    }

    /// ISO 8601 + 本机时区偏移（"2026-07-17T14:30:12+08:00"），分析时能还原"几点花的"
    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }
}
