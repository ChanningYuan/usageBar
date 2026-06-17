import Foundation

/// JSONL 流式读取辅助。
///
/// 用法：
/// ```swift
/// try JSONLReader.forEachLine(at: url) { obj in
///     guard let ts = obj["timestamp"] as? String else { return }
///     // ...
/// }
/// ```
public enum JSONLReader {

    /// 逐行读 JSONL 文件，把每行 parse 成 `[String: Any]` 后回调。
    /// 解析失败的行静默跳过（与 ai-token-stats.sh node 实现一致）。
    public static func forEachLine(
        at url: URL,
        body: (_ obj: [String: Any]) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var lineStart = 0
            for i in 0..<data.count {
                if bytes[i] == 0x0A {  // '\n'
                    if i > lineStart {
                        let slice = Data(bytes: bytes.advanced(by: lineStart), count: i - lineStart)
                        if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                            try body(obj)
                        }
                    }
                    lineStart = i + 1
                }
            }
            // 尾行无换行
            if lineStart < data.count {
                let slice = Data(bytes: bytes.advanced(by: lineStart), count: data.count - lineStart)
                if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                    try body(obj)
                }
            }
        }
    }

    /// 对 glob 路径下所有 jsonl 文件逐行遍历。
    public static func forEachLine(
        atFiles urls: [URL],
        body: (_ obj: [String: Any]) throws -> Void
    ) throws {
        for url in urls {
            try forEachLine(at: url, body: body)
        }
    }

    /// 简单的递归 find 实现：在 root 目录下找所有匹配 `predicate` 的文件。
    ///
    /// `includeHidden`：是否进入隐藏目录/文件。默认 false（跳过 `.xxx`）。
    /// Cowork 的 transcript 嵌在 `local_xxx/.claude/projects/...` 的隐藏 `.claude` 目录下，
    /// 必须传 true，否则枚举器不会下钻到 `.claude` 里，一个文件都找不到。
    public static func findFiles(
        under root: URL,
        includeHidden: Bool = false,
        where predicate: (URL) -> Bool
    ) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if predicate(url) { out.append(url) }
        }
        return out
    }
}

/// ISO 8601 时间戳解析（兼容 `Z` 和 `+00:00` 后缀）。
/// ISO8601DateFormatter 在 macOS 10.12+ 是线程安全的，用 nonisolated(unsafe) 标注。
public enum ISODateParser {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let formatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        if let d = formatter.date(from: s) { return d }
        if let d = formatterNoFrac.date(from: s) { return d }
        return nil
    }
}
