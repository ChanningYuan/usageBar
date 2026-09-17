import Foundation
import usageBarCore

/// Codex rollout 日志文件枚举（v0.3.40 起含归档对话）。主行 `CodexProvider` 与详情 `CodexDetailScanner` 共用。
///
/// ── 归档是「挪文件」──
/// Codex 侧边栏「归档」一条对话 = 把它的日志从 `sessions/YYYY/MM/DD/rollout-….jsonl` **挪到**同级
/// `archived_sessions/rollout-….jsonl`（平铺、文件名不变）；取消归档再按文件名里的日期挪回 `sessions/`。
/// 依据：openai/codex #20317（恢复后文件只剩 `sessions/2026/04/30/…`、`archived_sessions/` 里没有）、
/// #26174（`threads.rollout_path` 在两个目录间切换）；本机 2026-09-17 实测 `state_5.sqlite threads.archived=1`
/// 的那条 `rollout_path` 指向 `archived_sessions/`，`sessions/` 里已无同名文件。
///
/// ── ≤0.3.39 只扫 `sessions/` 的三个后果 ──
///  1. 归档前 usageBar 没扫到过的对话，用量永远不计（用户另一台机器归档很多，09-17 提出）；
///  2. 已计入的对话归档后，主列表按旧账本条目还在，详情页（每轮按现存文件重建）里却消失，两边对不上；
///  3. 父会话被归档的 fork 找不到差分基线，回放的父历史被整段算成新增。
///
/// ── 去重靠账本 key，不靠路径 ──
/// 同一个文件不管现在在哪个目录，账本 key 都按**文件名里的日期**还原成 `sessions/YYYY/MM/DD/<文件名>`
/// （本机 168 个文件实测目录日期 == 文件名日期，所以这就是它在活跃目录时的真实路径，老账本条目 key 不变）。
/// 归档 / 取消归档来回挪：key 不变、mtime 不变 → 直接命中旧条目，不会多出一条。
/// 两处同时有同名文件（取消归档没清干净等）只取一份：修改时间新的优先，再比大小，再优先活跃目录。
enum CodexRolloutFiles {
    struct File: Sendable {
        /// 文件现在的真实位置（读它）
        let url: URL
        /// 账本 key（存它、查它）
        let ledgerKey: String
    }

    /// `~/.codex/sessions` 的同级 `~/.codex/archived_sessions`
    static func archivedDir(forSessions sessionsDir: URL) -> URL {
        sessionsDir.deletingLastPathComponent().appendingPathComponent("archived_sessions")
    }

    /// `rollout-2026-08-11T21-17-10-<uuid>.jsonl` → `<sessionsDir>/2026/08/11/<文件名>`；文件名不合此格式返回 nil。
    static func ledgerKey(fileName: String, sessionsDir: URL) -> String? {
        let prefix = "rollout-"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".jsonl") else { return nil }
        let c = Array(fileName.dropFirst(prefix.count).prefix(11))   // "2026-08-11T"
        guard c.count == 11, c[4] == "-", c[7] == "-", c[10] == "T",
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ c[$0].isASCII && c[$0].isNumber })
        else { return nil }
        return sessionsDir
            .appendingPathComponent(String(c[0..<4]))
            .appendingPathComponent(String(c[5..<7]))
            .appendingPathComponent(String(c[8..<10]))
            .appendingPathComponent(fileName).path
    }

    /// 活跃 + 归档两处的 rollout 文件：按文件名去重，按文件名排序
    /// （`rollout-{ISO时间}-{uuid}` 字典序 == 时间序 → 父会话一定排在它的 fork 之前）。
    static func list(sessionsDir: URL, requirePath: String? = nil) -> [File] {
        let fm = FileManager.default
        func isRollout(_ url: URL) -> Bool {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { return false }
            if let req = requirePath, !url.path.contains(req) { return false }
            return true
        }
        struct Candidate { let url: URL; let mtime: Date; let size: Int; let archived: Bool }

        var best: [String: Candidate] = [:]
        func consider(_ url: URL, archived: Bool) {
            let m = FileMetadata.read(at: url.path)
            let cand = Candidate(url: url, mtime: m?.mtime ?? .distantPast, size: m?.size ?? 0, archived: archived)
            guard let cur = best[url.lastPathComponent] else {
                best[url.lastPathComponent] = cand
                return
            }
            let better: Bool
            if cand.mtime != cur.mtime { better = cand.mtime > cur.mtime }
            else if cand.size != cur.size { better = cand.size > cur.size }
            else { better = !cand.archived && cur.archived }
            if better { best[url.lastPathComponent] = cand }
        }

        if fm.fileExists(atPath: sessionsDir.path) {
            for url in JSONLReader.findFiles(under: sessionsDir, where: isRollout) { consider(url, archived: false) }
        }
        let archivedDir = archivedDir(forSessions: sessionsDir)
        if fm.fileExists(atPath: archivedDir.path) {
            for url in JSONLReader.findFiles(under: archivedDir, where: isRollout) { consider(url, archived: true) }
        }

        return best.keys.sorted().map { name in
            let url = best[name]!.url
            return File(url: url, ledgerKey: ledgerKey(fileName: name, sessionsDir: sessionsDir) ?? url.path)
        }
    }
}
