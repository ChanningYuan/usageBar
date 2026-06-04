import Foundation
import usageBarCore

/// QoderWork main.log → 本地 jsonl 的增量 mirror,防 QoderWork rotation 清掉历史
///
/// ## 数据流
/// ```
/// ~/Library/Application Support/QoderWork/logs/<ts>/main.log   (QoderWork 自己写,会 rotate)
///                ↓ 增量读 (按 size 单调递增水位线)
/// ~/Library/Application Support/usageBar/qoderwork-mainlog-capture.jsonl  (我们的存储,只增不减)
///                ↑ Provider 读
/// ```
///
/// ## Watermark schema
/// `~/Library/Application Support/usageBar/qoderwork-mainlog-watermark.json`
/// ```json
/// { "202605281557/main.log": 42417, "202605221757/main.log": 5541108 }
/// ```
///
/// 每个 main.log 的处理模式:
/// - 不在表里 → NEW (full scan from 0)
/// - size < prev_size → TRUNCATED (re-scan from 0,处理 QoderWork 截断/重写文件)
/// - size == prev_size → UNCHANGED (skip,fast path)
/// - size > prev_size → GREW (从 prev_size 字节开始读到 EOF)
///
/// ## 不完整尾行保护
/// 如果增量字节末尾没换行,说明最后一行还在写。本次只解析到最后一个换行符前,
/// watermark 不推进到 EOF (停在最后一个完整行结束位置),下次再来时把剩余补齐。
///
/// ## 行为一致性
/// 跟 `临时事项/2026-05-28-QoderWork今日数据原文对照/qoder_mainlog_mirror.py` 行为一致。
/// Python 脚本是本方案的测试验证脚本,6 个 case 全通过(详见 5/25 调研 README 第七次反向章节)。
///
/// ## 并发安全
/// runMirror 是「读 watermark → append jsonl → 存 watermark」的非原子序列。usageBar 唯一
/// 会**写**数据的 provider 就是它(其他 provider 纯读工具自己写的文件)。若两次 refresh 重叠
/// (10min 定时器 + 右键「立即刷新」),两个 runMirror 会读到同一旧 watermark,把同一段增量
/// append 两遍;capture.jsonl 只增不减 → qoder-work 永久虚高。
/// 因此**所有调用方必须走 `QoderWorkMirrorSerializer.shared.run()`**,由 actor 串行化,
/// 保证后一个一定读到前一个存好的新 watermark。禁止直接调 `runMirror()`。
public enum QoderWorkMainLogMirror {

    // MARK: - 路径

    /// QoderWork 自己的 logs root
    private static var logsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QoderWork/logs")
    }

    /// usageBar 自己的 data dir(跟 file-cache.json 同目录,会自动创建)
    private static var ourDataDir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("usageBar", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 镜像 jsonl 文件路径(QoderWorkProvider 读这个)
    public static var capturePath: URL {
        ourDataDir.appendingPathComponent("qoderwork-mainlog-capture.jsonl")
    }

    /// watermark 持久化文件
    private static var watermarkPath: URL {
        ourDataDir.appendingPathComponent("qoderwork-mainlog-watermark.json")
    }

    // MARK: - 入口

    /// 跑一次增量 mirror。fast path 在所有 main.log 都没变化时 ~3 个 stat 调用即返回。
    /// 返回本次新增 message_delta 行数(仅诊断用)。
    ///
    /// ⚠️ 非线程安全,不要直接调。统一走 `QoderWorkMirrorSerializer.shared.run()`(见文件头「并发安全」)。
    @discardableResult
    static func runMirror() -> Int {
        guard FileManager.default.fileExists(atPath: logsRoot.path) else { return 0 }

        // 1) 列出所有 logs/<ts>/main.log
        let mainLogs = findMainLogs()
        if mainLogs.isEmpty { return 0 }

        // 2) 加载 watermark
        var watermark = loadWatermark()

        // 3) 每个 main.log 增量处理
        var totalNewLines = 0
        for logURL in mainLogs {
            let key = "\(logURL.deletingLastPathComponent().lastPathComponent)/main.log"
            guard let meta = FileMetadata.read(at: logURL.path) else { continue }
            let currentSize = meta.size
            let prevSize = watermark[key]

            let readFrom: Int
            if prevSize == nil {
                readFrom = 0           // 新 dir
            } else if currentSize < prevSize! {
                readFrom = 0           // 截断重建
            } else if currentSize == prevSize! {
                continue               // 没变
            } else {
                readFrom = prevSize!   // 增量
            }

            let result = processIncrement(
                logURL: logURL,
                logPathKey: key,
                readFrom: readFrom,
                currentSize: currentSize
            )
            totalNewLines += result.newLines
            watermark[key] = result.newWatermark
        }

        // 4) 保存 watermark
        saveWatermark(watermark)
        return totalNewLines
    }

    // MARK: - 内部

    private static func findMainLogs() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.appendingPathComponent("main.log") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private struct IncrementResult {
        let newLines: Int
        let newWatermark: Int
    }

    private static func processIncrement(
        logURL: URL,
        logPathKey: String,
        readFrom: Int,
        currentSize: Int
    ) -> IncrementResult {
        // 读增量字节
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return IncrementResult(newLines: 0, newWatermark: readFrom)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(readFrom))
        } catch {
            return IncrementResult(newLines: 0, newWatermark: readFrom)
        }
        guard let chunk = try? handle.readToEnd(),
              var chunkStr = String(data: chunk, encoding: .utf8) else {
            return IncrementResult(newLines: 0, newWatermark: readFrom)
        }

        // 不完整尾行保护:如果末尾没换行,水位线只推到最后一个换行符位置
        var newWatermark = currentSize
        if !chunkStr.hasSuffix("\n") {
            if let lastNewlineIdx = chunkStr.lastIndex(of: "\n") {
                let incompleteTail = String(chunkStr[chunkStr.index(after: lastNewlineIdx)...])
                chunkStr = String(chunkStr[..<chunkStr.index(after: lastNewlineIdx)])
                newWatermark = currentSize - incompleteTail.utf8.count
            } else {
                // 整 chunk 都没换行,本次完全跳过等下次
                return IncrementResult(newLines: 0, newWatermark: readFrom)
            }
        }

        // 逐行解析 message_delta
        var records: [[String: Any]] = []
        for line in chunkStr.split(separator: "\n", omittingEmptySubsequences: true) {
            if let rec = parseMessageDeltaLine(String(line), logPathKey: logPathKey) {
                records.append(rec)
            }
        }

        // append 到 jsonl
        if !records.isEmpty {
            appendToJsonl(records: records)
        }

        return IncrementResult(newLines: records.count, newWatermark: newWatermark)
    }

    /// 解析单行日志,提取 SSE message_delta 事件
    /// 行格式:`[2026-05-28T02:15:05.241Z] [INFO] [SDK] [QueryHandler] Received message: stream_event {...}`
    private static func parseMessageDeltaLine(_ line: String, logPathKey: String) -> [String: Any]? {
        // 抽时间戳前缀 [...]
        guard line.hasPrefix("["),
              let tsEnd = line.firstIndex(of: "]") else { return nil }
        let tsStr = String(line[line.index(after: line.startIndex)..<tsEnd])

        // 抽 JSON 负载:第一个 { 到最后一个 } (兼容嵌套对象)
        guard let jsonStart = line.firstIndex(of: "{"),
              let jsonEnd = line.lastIndex(of: "}") else { return nil }
        let jsonStr = String(line[jsonStart...jsonEnd])

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // event 必须是 dict 且 type=message_delta(防御:实测有的行 event 是 string)
        guard let event = obj["event"] as? [String: Any],
              (event["type"] as? String) == "message_delta",
              let usage = event["usage"] as? [String: Any] else { return nil }

        // 时间戳 UTC → +08:00 ISO 字符串
        guard let utcDate = ISODateParser.parse(tsStr) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let tsLocal = formatter.string(from: utcDate)

        let inputTokens = (usage["input_tokens"] as? Int) ?? 0
        let outputTokens = (usage["output_tokens"] as? Int) ?? 0

        var record: [String: Any] = [
            "timestamp": tsLocal,
            "source": "qoderwork",
            "_via": "mainlog",
            "log_path": logPathKey,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            // mainlog 协议剥掉了 cache 拆分,这两个固定 0
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        ]
        if let sid = obj["session_id"] as? String { record["session_id"] = sid }
        if let uuid = obj["uuid"] as? String { record["uuid"] = uuid }
        return record
    }

    // MARK: - jsonl IO

    private static func appendToJsonl(records: [[String: Any]]) {
        var text = ""
        for r in records {
            guard let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { continue }
            text += line + "\n"
        }
        guard let data = text.data(using: .utf8) else { return }

        let url = capturePath
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        } else {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: - Watermark IO

    private static func loadWatermark() -> [String: Int] {
        guard let data = try? Data(contentsOf: watermarkPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return [:]
        }
        return obj
    }

    private static func saveWatermark(_ wm: [String: Int]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: wm,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: watermarkPath, options: .atomic)
    }
}

// MARK: - 串行化包装(并发安全唯一入口)

/// QoderWork mirror 的唯一对外入口。actor 保证两次 `run()` 不会交叠执行,
/// 后一个一定读到前一个存好的新 watermark,杜绝同段增量被 append 两遍导致的永久虚高。
public actor QoderWorkMirrorSerializer {
    public static let shared = QoderWorkMirrorSerializer()
    public init() {}

    /// 串行跑一次增量 mirror,返回本次新增行数(诊断用)。
    @discardableResult
    public func run() -> Int {
        QoderWorkMainLogMirror.runMirror()
    }
}
