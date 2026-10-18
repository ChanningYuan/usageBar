import Foundation
import CZstd

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
    ///
    /// `lineNeedle`：字节级预筛子串（0709 spec R3）。非 nil 时，行内**不含**该子串的行直接跳过
    /// `Data` 拷贝 + JSON 解析——日志里 99% 是与计量无关的内容行，全量解析是首扫慢的主因之一。
    /// ⚠️ 判据必须满足「目标行必然包含该子串」：只允许误放行（内容里恰好含关键字 → 多解析一行，
    /// 由回调里的结构 guard 兜住，不影响口径），**绝不允许漏掉目标行**。对拍单测锁此不变量。
    public static func forEachLine(
        at url: URL,
        lineNeedle: String? = nil,
        body: (_ obj: [String: Any]) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let needle: [UInt8] = lineNeedle.map { Array($0.utf8) } ?? []
        if url.pathExtension == "zst" {
            try forEachZstdLine(at: url, needle: needle, body: body)
            return
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)

            // memmem 是 libc 的高效子串搜索；needle 为空 = 不预筛，恒放行
            func lineMatches(_ start: Int, _ len: Int) -> Bool {
                guard !needle.isEmpty else { return true }
                guard len >= needle.count else { return false }
                return needle.withUnsafeBytes { np in
                    memmem(base.advanced(by: start), len, np.baseAddress!, needle.count) != nil
                }
            }
            func handle(_ start: Int, _ len: Int) throws {
                guard len > 0, lineMatches(start, len) else { return }
                let slice = Data(bytes: bytes.advanced(by: start), count: len)
                if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                    try body(obj)
                }
            }

            var lineStart = 0
            for i in 0..<data.count {
                if bytes[i] == 0x0A {  // '\n'
                    try handle(lineStart, i - lineStart)
                    lineStart = i + 1
                }
            }
            // 尾行无换行
            try handle(lineStart, data.count - lineStart)
        }
    }

    /// 回调里抛它 = 提前停（只读文件头几行时用，压缩文件不必整份解压）。调用方用 `try?` 吞掉即可。
    public struct StopReading: Error { public init() {} }

    /// 压缩文件坏了或没写完（最后一帧不完整）。调用方应当成「这次读不了」，别拿读了一半的数入账。
    public struct CorruptCompressedFile: Error {}

    /// `.jsonl.zst`（zstd 压缩的 JSONL）：Codex 桌面版 2026-10-16 起把旧对话日志压成这样（本机 209 个，
    /// 压缩后 474 MB、解压后 1.46 GB）。边解压边按行处理，不把整份解压结果放进内存；
    /// 预筛 / 解析 / 回调与未压缩文件完全一致。
    private static func forEachZstdLine(
        at url: URL, needle: [UInt8], body: (_ obj: [String: Any]) throws -> Void
    ) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let dctx = ZSTD_createDCtx() else { throw CorruptCompressedFile() }
        defer { ZSTD_freeDCtx(dctx) }

        var out = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var pending: [UInt8] = []
        var searchFrom = 0          // pending 里已确认没有换行的前缀长度（长行跨很多块时不重复扫）
        var lastResult = 0          // 0 = 一帧刚好解完；非 0 = 帧还没完

        func emit(_ line: ArraySlice<UInt8>) throws {
            guard !line.isEmpty else { return }
            try line.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                if !needle.isEmpty {
                    guard buf.count >= needle.count,
                          needle.withUnsafeBytes({ memmem(base, buf.count, $0.baseAddress!, needle.count) }) != nil
                    else { return }
                }
                if let obj = try? JSONSerialization.jsonObject(with: Data(buffer: buf)) as? [String: Any] {
                    try body(obj)
                }
            }
        }

        while let chunk = try file.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty {
            try chunk.withUnsafeBytes { raw in
                var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
                while input.pos < input.size {
                    let produced = try out.withUnsafeMutableBytes { ob -> Int in
                        var output = ZSTD_outBuffer(dst: ob.baseAddress, size: ob.count, pos: 0)
                        let rc = ZSTD_decompressStream(dctx, &output, &input)
                        if ZSTD_isError(rc) != 0 { throw CorruptCompressedFile() }
                        lastResult = rc
                        return output.pos
                    }
                    guard produced > 0 else { continue }
                    pending.append(contentsOf: out[0..<produced])
                    var lineStart = 0
                    var i = searchFrom
                    while i < pending.count {
                        if pending[i] == 0x0A {
                            try emit(pending[lineStart..<i])
                            lineStart = i + 1
                        }
                        i += 1
                    }
                    pending.removeSubrange(0..<lineStart)
                    searchFrom = pending.count
                }
            }
        }
        guard lastResult == 0 else { throw CorruptCompressedFile() }   // 文件在压缩途中被读到：这次不算
        try emit(pending[...])                                         // 尾行无换行
    }

    /// 对 glob 路径下所有 jsonl 文件逐行遍历。
    public static func forEachLine(
        atFiles urls: [URL],
        lineNeedle: String? = nil,
        body: (_ obj: [String: Any]) throws -> Void
    ) throws {
        for url in urls {
            try forEachLine(at: url, lineNeedle: lineNeedle, body: body)
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
