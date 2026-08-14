import Foundation
import usageBarCore

/// Qoder CLI 的**新日志源**：`~/.qoder/logs/sessions/**/segments/*.jsonl`（v0.3.33 接入）。
///
/// ## 为什么要有它（GitHub issue #8 症状二）
///
/// qodercli 1.1.13 起，大量调用带 `--print --no-session-persistence`（不保存可恢复会话）。
/// 这类请求**根本不写** `~/.qoder/projects/` 的 transcript，只把逐请求 token 真值写进
/// segments 诊断日志。旧版 usageBar 只扫 transcript，于是这部分用量**全部漏统**——
/// issue 报告人本机实测：8/5 之后 40 个新 segment、145 条非零 `model.response.completed`
/// 一条都没进主列表。
///
/// ## 新旧两套日志的关系（改这里前先读 `QoderCliProvider` 文件头的时间线表）
///
/// - **旧源** `projects/**/*.jsonl`：Claude 同款 transcript，去重键 `message.id`，
///   ~2026-08-05 之前为主，本版**保留读取**（已拍板 1b）。
/// - **新源** `logs/sessions/**/segments/*.jsonl`：事件流，去重键 `request_id`，8/5 之后为主。
///
/// ⚠️ **两套有重叠会话，绝不能直接相加**：同一个持久化会话的同一次请求，transcript 和 segment
/// 里都会出现。合并时按 `request_id` 跨源去重（见 `QoderCliProvider.fetchDailyRecords`）。
///
/// ## 解析口径
///
/// 与千问办公**逐字复用同一个解析器**（`QwenWorkSegmentParser`）——两者都是 Qoder 的 Go 引擎，
/// 千问办公只是 CN 变体（环境变量前缀 `QODERCN_` vs `QODER_`），日志 schema 完全一致：
/// `type == "model.response.completed"`、`ts`、`request_id`、`data.model`、四列 `data.*_tokens`。
/// 整轮汇总事件 `turn.finished` 明确忽略（与逐请求事件相加会双算）。
enum QoderCliSegmentSource {
    /// 新日志源根目录
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/logs/sessions")
    }

    /// 从 segment 事件流里取该会话的**工作目录**（`session.config.loaded` 的 `project_root` / `target_dir`）。
    ///
    /// 仅用于「这个会话在 `~/.qoder/projects` 里没有 transcript、拿不到正式标题」时的兜底显示名，
    /// **绝不参与任何 token 汇总**——token 口径仍然只认 `model.response.completed`（issue #8 的不变量）。
    ///
    /// ⚠️ 刻意**不解析** `input.prompt.received/submitted` 的 `text_preview`：它是从 prompt **开头**截断的，
    /// SDK / 桥接场景下前 1999 字符往往是 host 前言和旧对话历史（issue #10 报告人本机 27/37 条
    /// `truncated=true`），拿来当标题会显示误导内容，还可能把 system prompt、工具结果或敏感片段带到 UI 上。
    /// 宁可显示项目名。
    /// 📌 **不用 `input.prompt.*.query_source`（`tui` / `sdk`）当计量判据**（2026-08-14 评估后否掉）：
    /// 它确实能区分「人亲手敲的」和「非交互调用」，但**只存在于 segment 诊断日志，
    /// 而 Qoder 会定期把 segment 轮转删掉**（本机 7/14 的两份 8/14 就没了），
    /// transcript 却不会删 —— 判据会随日志清理而漂移，用量哪天自己涨回来且查不出原因，
    /// 除非再自建一套持久标记去对抗它。改用「有没有 transcript」，判据天然稳定。
    /// 详见 `QoderCliProvider.fetchDailyRecords` 的口径说明。
    static func projectRoot(in url: URL) -> String? {
        var found: String?
        try? JSONLReader.forEachLine(at: url) { obj in
            guard found == nil,
                  (obj["type"] as? String) == "session.config.loaded",
                  let data = obj["data"] as? [String: Any] else { return }
            for key in ["project_root", "target_dir"] {
                if let raw = data[key] as? String {
                    let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !v.isEmpty { found = v; return }
                }
            }
        }
        return found
    }
}

/// Qoder CLI segments 的按文件缓存 + 跨文件去重（与 `QwenWorkEventStore` 同构，各管各的根目录）。
///
/// 单独一个 actor 而不是复用千问那个：两者根目录不同、provider id 不同，
/// 合一会让缓存 key 冲突且 provider 归属混淆。
actor QoderCliSegmentStore {
    static let shared = QoderCliSegmentStore()

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let events: [QwenWorkUsageEvent]
        /// 该文件所属会话的工作目录（`session.config.loaded`），同一趟解析顺带取，供兜底标题用
        let projectRoot: String?
    }

    /// 一次扫描的产物：token 事件 + 会话展示元信息，两者职责分开、互不影响。
    struct Scan: Sendable {
        let events: [QwenWorkUsageEvent]
        /// sessionId → 工作目录绝对路径（v0.3.34 起，issue #10 的兜底标题来源）
        let projectRoots: [String: String]
    }

    private var cache: [String: CacheEntry] = [:]

    /// 读取该根目录下全部 segment 事件（按 (会话, 请求) 跨文件去重）+ 各会话的工作目录。
    ///
    /// 会话重启后可能新增 segment 文件并重放尾部事件，只按单文件去重会虚高，
    /// 故与千问一致：合并后统一去重。
    ///
    /// v0.3.34：顺带产出 `projectRoots`。**只在缓存未命中时多读一遍该文件**，
    /// 稳态（文件没变）零额外 IO；且工作目录不进任何 token 计算，纯展示用。
    func scan(under root: URL) -> Scan {
        var combined: [QwenWorkUsageEvent] = []
        var roots: [String: String] = [:]

        for url in QwenWorkSegmentParser.files(under: root).sorted(by: { $0.path < $1.path }) {
            let path = url.path
            guard let fileMeta = FileMetadata.read(at: path) else { continue }
            // sessionId 直接来自路径 `<sessionId>/segments/*.jsonl`，与解析器同源
            let sessionId = url.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent

            let entry: CacheEntry
            if let cached = cache[path], cached.mtime == fileMeta.mtime, cached.size == fileMeta.size {
                entry = cached
            } else {
                entry = CacheEntry(mtime: fileMeta.mtime, size: fileMeta.size,
                                   events: (try? QwenWorkSegmentParser.parseFile(url: url)) ?? [],
                                   projectRoot: QoderCliSegmentSource.projectRoot(in: url))
                cache[path] = entry
            }
            combined.append(contentsOf: entry.events)
            if let r = entry.projectRoot { roots[sessionId] = roots[sessionId] ?? r }
        }

        var seen = Set<String>()
        let events = combined
            .sorted { $0.timestamp < $1.timestamp }
            .filter { seen.insert("\($0.sessionId)\u{0}\($0.requestId)").inserted }
        return Scan(events: events, projectRoots: roots)
    }

    func invalidate() { cache.removeAll() }
}
