import Foundation
import CoreFoundation
import CryptoKit
import usageBarCore

/// 积分采集不参与 token 计算；独立补扫旧 transcript，写入同一持久账本。
public enum QoderCreditsReader {
    public static let ledgerPrefix = "usagebar://qoder-credits"

    public static func refresh(root: URL, ledger: FileMtimeCache) async {
        let root = root.resolvingSymlinksInPath()
        let fm = FileManager.default
        var status = QoderCreditFile(sourcePath: root.path)
        status.modelNames = modelNames(at: root.deletingLastPathComponent().appendingPathComponent(".auth/models"))
        let enumeration = enumerate(root: root)
        let files = enumeration.files
        status.unreadable = enumeration.failed
        let existing = Set(files.map(\.path))
        for url in files.sorted(by: { $0.path < $1.path }) {
            let key = ledgerPrefix + url.path
            let old = await ledger.entry(forPath: key)
            guard let meta = FileMetadata.read(at: url.path) else {
                var failed = old?.qoderCredits ?? QoderCreditFile(sourcePath: url.path)
                failed.unreadable = true
                await ledger.store(FileCacheEntry(filePath: key, mtime: .distantPast, size: -1,
                                                   records: [], qoderCredits: failed))
                continue
            }
            // 积分可能同长度原地更新，不能沿用 token 缓存的 1 秒 mtime 容差。
            if let hit = old, hit.mtime == meta.mtime, hit.size == meta.size,
               let data = hit.qoderCredits, data.version == 1, !data.unreadable, !data.sourceMissing {
                continue
            }
            var parsed: QoderCreditFile
            do {
                parsed = try parse(url: url)
                // 日志轮转/截断不是撤销消费；新观测只覆盖同一记录，旧观测仍保留。
                var retained = Dictionary((old?.qoderCredits?.observations ?? []).map { ($0.recordKey, $0) },
                                          uniquingKeysWith: { _, new in new })
                for observation in parsed.observations { retained[observation.recordKey] = observation }
                parsed.observations = retained.values.sorted { $0.recordKey < $1.recordKey }
                parsed.titles.merge(old?.qoderCredits?.titles ?? [:]) { current, _ in current }
            } catch {
                parsed = old?.qoderCredits ?? QoderCreditFile(sourcePath: url.path)
                parsed.unreadable = true
            }
            await ledger.store(FileCacheEntry(filePath: key, mtime: meta.mtime, size: meta.size,
                                               records: [], qoderCredits: parsed))
        }
        for entry in await ledger.allEntries() {
            guard var data = entry.qoderCredits, data.sourcePath.hasPrefix(root.path + "/"),
                  !existing.contains(data.sourcePath) else { continue }
            data.sourceMissing = !fm.fileExists(atPath: data.sourcePath)
            if !data.sourceMissing { data.unreadable = true }
            await ledger.store(FileCacheEntry(filePath: entry.filePath, mtime: entry.mtime, size: entry.size,
                                               records: entry.records, details: entry.details, qoderCredits: data))
        }
        await ledger.store(FileCacheEntry(filePath: ledgerPrefix + root.path + "/scan", mtime: Date(),
                                           size: 0, records: [], qoderCredits: status))
    }

    private static func enumerate(root: URL) -> (files: [URL], failed: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return ([], false) }
        var failed = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in
            failed = true
            return true
        }) else { return ([], true) }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url.resolvingSymlinksInPath())
        }
        return (files, failed)
    }

    static func parse(url: URL) throws -> QoderCreditFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var file = QoderCreditFile(sourcePath: url.path)
        var records: [String: QoderCreditObservation] = [:]
        var anonymousOccurrences: [String: Int] = [:]
        let subagent = url.deletingLastPathComponent().lastPathComponent == "subagents"
            ? url.deletingPathExtension().lastPathComponent : nil
        let expectedSession = subagent == nil ? url.deletingPathExtension().lastPathComponent
            : url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                file.malformedRecords += 1; continue
            }
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            // 显式未完成的流式片段不记；旧格式不含 stop_reason 时保留，依请求标识去重。
            if message["stop_reason"] is NSNull { continue }
            guard let timestamp = (obj["timestamp"] as? String).flatMap(ISODateParser.parse) else {
                file.malformedRecords += 1; continue
            }
            func identifier(_ value: Any?) -> String? {
                guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return string
            }
            let requestId = identifier(usage["request_id"])
            let messageId = identifier(message["id"])
            let uuid = identifier(obj["uuid"])
            let kind = requestId != nil ? "request" : messageId != nil ? "message" : uuid != nil ? "record" : "local"
            // 无编号时仅在原文件内稳定识别；截断后不能按旧行号覆盖另一条历史请求。
            var anonymousKey = ""
            if kind == "local" {
                let hash = SHA256.hash(data: Data(line)).map { String(format: "%02x", $0) }.joined()
                anonymousOccurrences[hash, default: 0] += 1
                anonymousKey = "\(url.path):\(hash):\(anonymousOccurrences[hash]!)"
            }
            let key = "\(kind):" + (requestId ?? messageId ?? uuid ?? anonymousKey)
            let recordKey = uuid.map { "record:\($0)" } ?? messageId.map { "message:\($0)" } ?? key
            let session = identifier(obj["sessionId"]) ?? identifier(obj["session_id"]) ?? expectedSession
            let model = identifier(message["model"]) ?? "(模型未知)"
            if model == "<synthetic>" { continue }
            var invalid: [String] = []
            func number(_ field: String) -> Decimal? {
                guard let value = usage[field], !(value is NSNull) else { return nil }
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite, n.doubleValue >= 0,
                      let result = Decimal(string: n.stringValue, locale: Locale(identifier: "en_US_POSIX")),
                      !result.isNaN else {
                    invalid.append(field); return nil
                }
                return result
            }
            let credits = number("credits"), original = number("original_credits")
            let billable = boolean(usage["billable"])
            if usage["billable"] != nil && !(usage["billable"] is NSNull) && billable == nil { invalid.append("billable") }
            var observation = QoderCreditObservation(
                recordKey: recordKey, requestKey: key, identityKind: kind, timestamp: timestamp,
                sessionId: session, model: model, credits: credits, originalCredits: original,
                billable: billable, subagentId: subagent, isSidechain: boolean(obj["isSidechain"]),
                attributionConflict: session != expectedSession, invalidFields: invalid)
            // 同一消息编号的积分也可能被原地改写。保存观测版本，不能静默取最后一个金额。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let fingerprint = SHA256.hash(data: try encoder.encode(observation))
                .map { String(format: "%02x", $0) }.joined()
            observation.recordKey += ":" + fingerprint
            records[observation.recordKey] = observation
        }
        file.observations = records.values.sorted { $0.recordKey < $1.recordKey }
        // 复用既有标题优先级；子代理文件的首条正文不覆盖主会话标题。
        if subagent == nil { file.titles = ClaudeDetailScanner.index(url: url).titles }
        return file
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func modelNames(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var names: [String: String] = [:]
        func visit(_ value: Any) {
            if let rows = value as? [Any] { rows.forEach(visit) }
            else if let row = value as? [String: Any] {
                if let key = row["key"] as? String, let name = row["display_name"] as? String,
                   !name.isEmpty, !["auto", "ultimate", "performance", "efficient", "lite"].contains(key.lowercased()) {
                    names[key] = name
                }
                for child in row.values where child is [Any] || child is [String: Any] { visit(child) }
            }
        }
        visit(object)
        return names
    }
}
