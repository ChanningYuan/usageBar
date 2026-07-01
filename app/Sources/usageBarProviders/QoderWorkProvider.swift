import Foundation
import usageBarCore

/// QoderWork provider — 双源相加版(2026-06-24 接入新 transcript)
///
/// ## 背景:0.6.3 换了 token 落点
/// QoderWork 桌面 app 升级到 **0.6.3** 后,不再往 main.log 写 SDK 的 SSE `message_delta` 帧
/// (旧 mirror 源就此干涸、`Qoder (Work)` 归零),真实 token 改落到 transcript:
///   `~/.qoderwork/projects/<workspace>/<sessionId>.jsonl`(+ `subagents/` 递归子目录)
/// 结构与 Qoder CLI / Claude Code 的 transcript 同款(逐行一个事件对象)。
/// 与 `~/.qoder`(CLI)是两个物理隔离目录,互不串。
///
/// ## 两个数据源(按天相加)
/// - 源 A · 旧 main.log mirror —— 0.5.8 时代真实历史,冻结档,0.6.3 下基本不再增长
///   `~/Library/Application Support/usageBar/qoderwork-mainlog-capture.jsonl`
/// - 源 B · 新 transcript —— 0.6.3 起的真实 token
///   取 `type=="assistant"` 行的 `message.usage` 四列;`total==0` 自动过滤噪声行
///   (model=None 的旧空壳行 / 流式分片)。
///
/// 两源真实 token 的时间段不重叠、session 无撞车(实测交集为空):0.6.3 重启前的 session 在
/// transcript 里是 model=None(新源贡献 0),重启后的 session 不在已死的 main.log 里。按天相加零双算。
/// 下游 `DailyAggregator` 按 (provider,date) 求和,本 provider 直接拼接两源 records 返回即可。
///
/// ⚠️ token 真值受环境变量 `QODER_EXPOSE_TOKEN_USAGE` gate 控制(与 Qoder CLI **共用同一个** gate):
///    没设该变量时 transcript 的 `message.usage` 缺失/全 0(2026-06-25 双机实测证实,推翻早前"Work 与
///    env 无关"的判断 —— 当初那台其实 .zshrc 里有该 export,Work 靠 zsh -ilc 抓登录 shell env 继承了它)。
///    开关由 `QoderUsageEnvGate` + UI 层管(写 .zshrc;QoderWork 是 GUI app,改完需重启才生效)。
///    本 provider 只管解析 transcript,不在此引入 env 检测。详见 `docs/0625-Qoder全家桶token计量/qoder-family-token-gate.md`。
public struct QoderWorkProvider: UsageProvider {
    public let id = "qoder-work"
    public let displayName = "Qoder (Work)"
    public let iconSymbol = "rectangle.stack.badge.plus"
    public let brandColor = "#0E7A5F"
    public var family: String? { "qoder" }

    private var transcriptDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".qoderwork/projects")
    }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        var all: [FileDailyRecord] = []
        all += await mirrorRecords()       // 源 A:历史(冻结)
        all += await transcriptRecords()   // 源 B:现行
        return all
    }

    // MARK: - 源 A · main.log mirror(历史,冻结)

    private func mirrorRecords() async -> [FileDailyRecord] {
        // 跑一次增量 mirror(0.6.3 下基本 no-op,留着兜底任何残留 message_delta)。
        // serializer actor 串行化,防两次 refresh 重叠把同段增量 append 两遍(永久虚高)。
        _ = await QoderWorkMirrorSerializer.shared.run()

        let path = QoderWorkMainLogMirror.capturePath.path
        guard let meta = FileMetadata.read(at: path) else { return [] }

        if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
            return entry.records
        }

        let records = (try? parseMirrorFile(url: URL(fileURLWithPath: path))) ?? []
        let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
        await FileMtimeCache.shared.store(entry)
        return records
    }

    private func parseMirrorFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]

        try JSONLReader.forEachLine(at: url) { obj in
            guard (obj["source"] as? String) == "qoderwork",
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }

            let input = (obj["input_tokens"] as? Int) ?? 0
            let output = (obj["output_tokens"] as? Int) ?? 0
            let cacheCreation = (obj["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (obj["cache_read_input_tokens"] as? Int) ?? 0
            let total = input + output + cacheCreation + cacheRead
            if total == 0 { return }

            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
            dailyCached[date, default: 0] += cacheRead   // 源A历史 mirror cache 恒0，一致起见仍累加
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }

    // MARK: - 源 B · ~/.qoderwork/projects transcript(现行,含 subagents 递归)

    private func transcriptRecords() async -> [FileDailyRecord] {
        guard FileManager.default.fileExists(atPath: transcriptDir.path) else { return [] }

        let jsonlFiles = JSONLReader.findFiles(under: transcriptDir) { url in
            url.pathExtension == "jsonl"
        }

        var allRecords: [FileDailyRecord] = []
        for url in jsonlFiles {
            let path = url.path
            guard let meta = FileMetadata.read(at: path) else { continue }

            if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
                allRecords.append(contentsOf: entry.records)
                continue
            }

            let records = (try? parseTranscriptFile(url: url)) ?? []
            let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
            await FileMtimeCache.shared.store(entry)
            allRecords.append(contentsOf: records)
        }

        return allRecords
    }

    private func parseTranscriptFile(url: URL) throws -> [FileDailyRecord] {
        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]

        try JSONLReader.forEachLine(at: url) { obj in
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = ISODateParser.parse(tsStr)
            else { return }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let total = input + output + cacheCreation + cacheRead
            if total == 0 { return }   // model=None / 流式分片 / 旧空壳行全在此丢弃

            let date = DailyAggregator.dateString(for: ts)
            dailyTotals[date, default: 0] += total
            dailyCached[date, default: 0] += cacheRead   // 浅色：仅命中读取
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }
}
