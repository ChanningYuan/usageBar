import Foundation
import usageBarCore

/// 这台电脑哪天用过豆包工作（v0.3.48）——只用来决定「今日」要不要显示豆包工作那一行。
///
/// ## 为什么要分本机
///
/// 豆包工作的积分是**账号级**的：手机豆包 App、另一台电脑上的豆包工作都扣同一份积分，
/// 明细接口里没有「哪个端」的字段。0.3.47 主列表只看「当期有没有积分」，于是这台电脑一整天
/// 没开豆包工作，今日也冒出一行灰色 0 的「豆包工作」（2026-10-18 用户反馈）。
/// 用户 10-19 定：**只有今日**按本机当天用没用过决定显示，本周 / 本月 / 累计照旧按账号看。
///
/// ## 证据从哪来
///
/// 豆包工作本机聊天库（IndexedDB `doubaowork-chat`）缓存着对话列表，每个对话带更新时间：
/// - **任务对话**带 `device_reference.device_id`：等于本机 `Local State` 的 `aha.device.device_id` 才算；
/// - **普通聊天**不带设备号，同账号各台电脑的豆包工作都会同步进来（手机豆包 App 的对话不在里面）
///   → 只有更新那一刻豆包工作正在本机最前面才算（前台时段由 usageBar 自己记，见 `noteForeground`）。
///
/// ⚠️ 别退回成「聊天库文件今天改过」：豆包工作一打开就改写聊天库（10-09 14:39 自动更新重启，
/// 前后一笔积分都没有），开着时也会把别处的对话同步进来。
///
/// 2026-10-19 本机核对：7 个本机任务对话的更新时间与 09-03～09-24 的豆包工作积分逐笔对上；
/// 10-07 两个普通聊天（10:33 / 12:43）更新时本机豆包工作窗口在后台（07:34～17:53），是别的设备问的。
public struct DoubaoWorkConversation: Sendable, Equatable {
    public let id: String
    public let updatedAt: Date
    /// 任务对话所在设备；普通聊天为 nil
    public let deviceId: String?

    public init(id: String, updatedAt: Date, deviceId: String?) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceId = deviceId
    }
}

public enum DoubaoWorkLocalUse {
    public static let bundleIdentifier = "com.work.pc.doubao"
    /// 普通聊天的更新时间与本机前台时段的容差：服务端时间与本机时钟有偏差，发出到列表更新也要几秒
    static let foregroundTolerance: TimeInterval = 120

    /// 本机用过豆包工作的日期（`yyyy-MM-dd`）。
    public static func activeDates(
        conversations: [DoubaoWorkConversation],
        localDeviceId: String?,
        foreground: [DateInterval]
    ) -> Set<String> {
        var dates = Set<String>()
        for c in conversations {
            if let device = c.deviceId, let localDeviceId {
                guard device == localDeviceId else { continue }
            } else {
                let inForeground = foreground.contains {
                    $0.start.addingTimeInterval(-foregroundTolerance) <= c.updatedAt
                        && c.updatedAt <= $0.end.addingTimeInterval(foregroundTolerance)
                }
                guard inForeground else { continue }
            }
            dates.insert(DailyAggregator.dateString(for: c.updatedAt))
        }
        return dates
    }

    /// 聊天库目录里的全部对话（同一对话在新旧版本记录里都出现时取最新的更新时间）。
    static func conversations(inChatDatabase directory: URL) -> [DoubaoWorkConversation] {
        var latest: [String: DoubaoWorkConversation] = [:]
        for payload in ChromiumLevelDB.payloads(in: directory) {
            for record in V8Reader.objects(in: payload) {
                collect(record, into: &latest)
            }
        }
        return latest.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    private static func collect(_ value: Any, into latest: inout [String: DoubaoWorkConversation]) {
        if let dict = value as? [String: Any] {
            if let id = dict["conversation_id"] as? String, !id.isEmpty,
               let updated = date(dict["update_time"]) {
                let ref = dict["device_reference"] as? [String: Any]
                let device = (ref?["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let key = id + "\u{0}" + (device ?? "")
                if (latest[key]?.updatedAt ?? .distantPast) < updated {
                    latest[key] = DoubaoWorkConversation(id: id, updatedAt: updated, deviceId: device)
                }
            }
            for child in dict.values { collect(child, into: &latest) }
        } else if let array = value as? [Any] {
            for child in array { collect(child, into: &latest) }
        }
    }

    /// 更新时间：本机样本是秒级数字串（`"1791348186"`），也兼容数字与毫秒
    private static func date(_ raw: Any?) -> Date? {
        let seconds: Double?
        switch raw {
        case let s as String: seconds = Double(s)
        case let d as Double: seconds = d
        case let i as Int: seconds = Double(i)
        default: seconds = nil
        }
        guard var v = seconds, v > 0 else { return nil }
        if v > 1e12 { v /= 1000 }
        return Date(timeIntervalSince1970: v)
    }
}

/// 本机用过豆包工作的日期 + 豆包工作在前台的时段（持久化，usageBar 重启后当天的证据还在）。
///
/// 聊天库只留每个对话**最后一次**更新时间：上午在本机聊过、下午别的设备接着聊同一个对话，
/// 上午那次的证据就被覆盖了——所以认定过的日期要自己记下来。
public actor DoubaoWorkLocalUseStore {
    public static let shared = DoubaoWorkLocalUseStore()

    private static let cacheVersion = 1
    /// 前台时段只用来比对普通聊天的更新时间，留两天够跨零点
    private static let foregroundRetention: TimeInterval = 2 * 86_400
    private static let dateRetentionDays = 40

    private struct Span: Codable { let start: Date; let end: Date }
    private struct CacheFile: Codable {
        let version: Int
        let activeDates: [String]
        let foreground: [Span]
    }

    private let fileURL: URL
    private let dataDirectory: URL
    private var activeDates: Set<String> = []
    private var foreground: [DateInterval] = []
    private var loaded = false
    /// 聊天库文件的（名字 → 修改时间 + 大小）；没变就不重读
    private var scannedSignature: [String: [Double]] = [:]
    private var conversations: [DoubaoWorkConversation] = []

    public static var defaultPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("usageBar", isDirectory: true)
            .appendingPathComponent("doubao-work-local.json")
    }

    init(fileURL: URL = DoubaoWorkLocalUseStore.defaultPath, dataDirectory: URL = DoubaoWorkEnv.dataDirectory) {
        self.fileURL = fileURL
        self.dataDirectory = dataDirectory
    }

    private var chatDatabase: URL {
        dataDirectory.appendingPathComponent("Default/IndexedDB/chrome_doubaowork-chat_0.indexeddb.leveldb", isDirectory: true)
    }

    /// 豆包工作在本机前台待过一段（切走 / 退出时由 App 层报上来）。
    public func noteForeground(_ interval: DateInterval, now: Date = Date()) {
        loadIfNeeded()
        foreground.append(interval)
        foreground.removeAll { $0.end < now.addingTimeInterval(-Self.foregroundRetention) }
        persist()
    }

    /// 本机用过豆包工作的日期。`openForegroundSince`：豆包工作此刻正在前台时，从什么时候起。
    public func activeDates(now: Date = Date(), openForegroundSince: Date? = nil) -> Set<String> {
        loadIfNeeded()
        rescanIfChanged()
        var spans = foreground
        if let since = openForegroundSince { spans.append(DateInterval(start: since, end: max(since, now))) }
        let localDevice = DoubaoWorkAPI.RequestContext.deviceId(localState: dataDirectory.appendingPathComponent("Local State"))
        let found = DoubaoWorkLocalUse.activeDates(conversations: conversations, localDeviceId: localDevice, foreground: spans)
        let cutoff = DailyAggregator.dateString(for: now.addingTimeInterval(-Double(Self.dateRetentionDays) * 86_400))
        let merged = activeDates.union(found).filter { $0 >= cutoff }
        if merged != activeDates {
            activeDates = merged
            persist()
        }
        return activeDates
    }

    private func rescanIfChanged() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: chatDatabase.path)) ?? []
        var signature: [String: [Double]] = [:]
        for name in names where name.hasSuffix(".ldb") || name.hasSuffix(".log") {
            guard let meta = FileMetadata.read(at: chatDatabase.appendingPathComponent(name).path) else { continue }
            signature[name] = [meta.mtime.timeIntervalSince1970, Double(meta.size)]
        }
        guard signature != scannedSignature else { return }
        scannedSignature = signature
        conversations = DoubaoWorkLocalUse.conversations(inChatDatabase: chatDatabase)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let cache = try? decoder.decode(CacheFile.self, from: data),
              cache.version == Self.cacheVersion else { return }
        activeDates = Set(cache.activeDates)
        foreground = cache.foreground.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
    }

    private func persist() {
        let file = CacheFile(version: Self.cacheVersion,
                             activeDates: activeDates.sorted(),
                             foreground: foreground.map { Span(start: $0.start, end: $0.end) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Chromium LevelDB（只读，够读 IndexedDB 的值就行）

/// 读 `.ldb` 表的数据块（snappy 解压）和 `.log` 的完整记录，交给上层去找值。
/// 不解析键、不按序列号去重：同一条记录的新旧版本都会出现，由调用方取最新。
/// 豆包工作开着也能读——只读文件，不碰 `LOCK`；读到写了一半的块就跳过。
enum ChromiumLevelDB {
    static func payloads(in directory: URL) -> [[UInt8]] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [[UInt8]] = []
        for name in names.sorted() where name.hasSuffix(".ldb") || name.hasSuffix(".log") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            let bytes = [UInt8](data)
            out += name.hasSuffix(".ldb") ? tableBlocks(bytes) : logRecords(bytes)
        }
        return out
    }

    /// 表文件：48 字节尾部 → 索引块 → 各数据块
    static func tableBlocks(_ b: [UInt8]) -> [[UInt8]] {
        guard b.count >= 48 else { return [] }
        var i = b.count - 48
        guard varint(b, &i) != nil, varint(b, &i) != nil,           // 元数据索引，不用
              let indexOffset = varint(b, &i), let indexSize = varint(b, &i),
              let index = block(b, offset: indexOffset, size: indexSize), index.count >= 4
        else { return [] }
        let restarts = Int(index[index.count - 4]) | Int(index[index.count - 3]) << 8
            | Int(index[index.count - 2]) << 16 | Int(index[index.count - 1]) << 24
        let end = index.count - 4 - 4 * restarts
        var blocks: [[UInt8]] = []
        var j = 0
        while j < end {
            guard varint(index, &j) != nil, let keyLength = varint(index, &j),
                  let valueLength = varint(index, &j) else { break }
            j += keyLength
            var k = j
            guard j + valueLength <= index.count,
                  let offset = varint(index, &k), let size = varint(index, &k) else { break }
            j += valueLength
            if let data = block(b, offset: offset, size: size) { blocks.append(data) }
        }
        return blocks
    }

    private static func block(_ b: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, offset + size + 5 <= b.count else { return nil }
        let raw = Array(b[offset..<(offset + size)])
        switch b[offset + size] {      // 块尾：1 字节压缩类型 + 4 字节校验
        case 0: return raw
        case 1: return Snappy.decompress(raw)
        default: return nil
        }
    }

    /// 日志文件：32 KB 一块，每条记录 7 字节头（校验 4 + 长度 2 + 类型 1），跨块的记录按类型拼回
    static func logRecords(_ b: [UInt8]) -> [[UInt8]] {
        let blockSize = 32_768
        var out: [[UInt8]] = []
        var pending: [UInt8] = []
        var blockStart = 0
        while blockStart < b.count {
            let blockEnd = min(blockStart + blockSize, b.count)
            var i = blockStart
            while i + 7 <= blockEnd {
                let length = Int(b[i + 4]) | Int(b[i + 5]) << 8
                let type = b[i + 6]
                let start = i + 7
                guard type != 0, start + length <= blockEnd else { break }
                let fragment = b[start..<(start + length)]
                switch type {
                case 1: out.append(Array(fragment)); pending = []          // 完整
                case 2: pending = Array(fragment)                          // 开头
                case 3: pending += fragment                                // 中间
                case 4: pending += fragment; out.append(pending); pending = []   // 结尾
                default: break
                }
                i = start + length
            }
            blockStart += blockSize
        }
        return out
    }

    static func varint(_ b: [UInt8], _ i: inout Int) -> Int? {
        var result = 0
        var shift = 0
        while i < b.count, shift < 64 {
            let byte = b[i]
            i += 1
            result |= Int(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }
}

enum Snappy {
    static func decompress(_ b: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let expected = ChromiumLevelDB.varint(b, &i), expected < 64 << 20 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(expected)
        while i < b.count {
            let tag = b[i]
            i += 1
            switch tag & 3 {
            case 0:                                    // 原样字节
                var length = Int(tag >> 2)
                if length >= 60 {
                    let width = length - 59
                    guard i + width <= b.count else { return nil }
                    length = 0
                    for k in 0..<width { length |= Int(b[i + k]) << (8 * k) }
                    i += width
                }
                length += 1
                guard i + length <= b.count else { return nil }
                out += b[i..<(i + length)]
                i += length
            case 1:                                    // 回拷，1 字节偏移
                guard i < b.count else { return nil }
                let length = Int((tag >> 2) & 7) + 4
                let offset = Int(tag >> 5) << 8 | Int(b[i])
                i += 1
                guard copyBack(&out, offset: offset, length: length) else { return nil }
            case 2:                                    // 回拷，2 字节偏移
                guard i + 2 <= b.count else { return nil }
                let offset = Int(b[i]) | Int(b[i + 1]) << 8
                i += 2
                guard copyBack(&out, offset: offset, length: Int(tag >> 2) + 1) else { return nil }
            default:                                   // 回拷，4 字节偏移
                guard i + 4 <= b.count else { return nil }
                let offset = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
                i += 4
                guard copyBack(&out, offset: offset, length: Int(tag >> 2) + 1) else { return nil }
            }
        }
        return out.count == expected ? out : nil
    }

    private static func copyBack(_ out: inout [UInt8], offset: Int, length: Int) -> Bool {
        guard offset > 0, offset <= out.count else { return false }
        let start = out.count - offset
        for k in 0..<length { out.append(out[start + k]) }
        return true
    }
}

// MARK: - V8 序列化值（IndexedDB 存的 JS 对象）

/// 只认对话列表用得到的几种值；遇到不认识的标签整条放弃——豆包工作改格式时宁可少认，不认错。
struct V8Reader {
    private let b: [UInt8]
    private var i: Int

    /// payload 里每个以 `0xFF 版本号 'o'` 开头的 JS 对象
    static func objects(in payload: [UInt8]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        while i + 2 < payload.count {
            if payload[i] == 0xFF, (0x0D...0x16).contains(payload[i + 1]), payload[i + 2] == 0x6F {
                var reader = V8Reader(b: payload, i: i + 2)
                if let object = reader.value(depth: 0) as? [String: Any] { out.append(object) }
            }
            i += 1
        }
        return out
    }

    private mutating func varint() -> Int? { ChromiumLevelDB.varint(b, &i) }

    private mutating func bytes(_ n: Int) -> ArraySlice<UInt8>? {
        guard n >= 0, i + n <= b.count else { return nil }
        defer { i += n }
        return b[i..<(i + n)]
    }

    private mutating func value(depth: Int) -> Any? {
        guard depth < 64, i < b.count else { return nil }
        let tag = b[i]
        i += 1
        switch tag {
        case 0x00: return value(depth: depth)                                   // 对齐填充
        case 0x22:                                                              // " 单字节串
            guard let n = varint(), let s = bytes(n) else { return nil }
            return String(bytes: s, encoding: .isoLatin1)
        case 0x63:                                                              // c 双字节串
            guard let n = varint(), n % 2 == 0, let s = bytes(n) else { return nil }
            let units = stride(from: s.startIndex, to: s.endIndex, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        case 0x53:                                                              // S UTF-8 串
            guard let n = varint(), let s = bytes(n) else { return nil }
            return String(decoding: s, as: UTF8.self)
        case 0x49:                                                              // I 有符号整数
            guard let z = varint() else { return nil }
            return (z >> 1) ^ -(z & 1)
        case 0x55: return varint()                                              // U 无符号整数
        case 0x4E:                                                              // N 双精度
            guard let s = bytes(8) else { return nil }
            var bits: UInt64 = 0
            for (k, byte) in s.enumerated() { bits |= UInt64(byte) << (8 * UInt64(k)) }
            return Double(bitPattern: bits)
        case 0x54: return true
        case 0x46: return false
        case 0x30, 0x5F, 0x2D: return NSNull()                                  // null / undefined / 空洞
        case 0x5E: return varint().map { _ in NSNull() }                         // 对象引用，不展开
        case 0x6F:                                                              // o 对象
            var object: [String: Any] = [:]
            while i < b.count, b[i] != 0x7B {
                guard let key = value(depth: depth + 1), let v = value(depth: depth + 1) else { return nil }
                object[(key as? String) ?? "\(key)"] = v
            }
            i += 1
            return varint().map { _ in object }
        case 0x41:                                                              // A 稠密数组
            guard let n = varint(), n <= b.count else { return nil }
            var array: [Any] = []
            for _ in 0..<n {
                guard let v = value(depth: depth + 1) else { return nil }
                array.append(v)
            }
            while i < b.count, b[i] != 0x24 {
                guard value(depth: depth + 1) != nil, value(depth: depth + 1) != nil else { return nil }
            }
            i += 1
            guard varint() != nil, varint() != nil else { return nil }
            return array
        case 0x61:                                                              // a 稀疏数组
            guard varint() != nil else { return nil }
            var array: [Any] = []
            while i < b.count, b[i] != 0x40 {
                guard value(depth: depth + 1) != nil, let v = value(depth: depth + 1) else { return nil }
                array.append(v)
            }
            i += 1
            guard varint() != nil, varint() != nil else { return nil }
            return array
        default:
            return nil
        }
    }
}
