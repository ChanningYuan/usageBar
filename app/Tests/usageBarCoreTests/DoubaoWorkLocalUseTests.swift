import XCTest
@testable import usageBarProviders
import usageBarCore

/// 「今日」的豆包工作只认本机用过的那天（v0.3.48）。
/// 0.3.47 现场：这台电脑 10-10 起没开过豆包工作，手机上问的积分照样让今日冒出「豆包工作」一行。
final class DoubaoWorkLocalUseTests: XCTestCase {
    private let local = "1000000000000001"
    private let morning = Date(timeIntervalSince1970: 1_791_348_186)          // 2026-10-07 12:43 (+08:00)

    // MARK: 认定规则

    /// 任务对话带设备号：本机的算，另一台设备的不算。
    func testTaskConversationCountsOnlyOnThisDevice() {
        let mine = DoubaoWorkConversation(id: "a", updatedAt: morning, deviceId: local)
        let other = DoubaoWorkConversation(id: "b", updatedAt: morning.addingTimeInterval(86_400), deviceId: "1000000000000002")
        let dates = DoubaoWorkLocalUse.activeDates(conversations: [mine, other], localDeviceId: local, foreground: [])
        XCTAssertEqual(dates, [DailyAggregator.dateString(for: morning)])
    }

    /// ⛔ 普通聊天不带设备号、同账号各台电脑都会同步：只有更新那一刻豆包工作在本机最前面才算。
    /// 10-07 现场：两个普通聊天更新时本机窗口在后台，是别的设备问的。
    func testChatConversationNeedsThisMacInForeground() {
        let chat = DoubaoWorkConversation(id: "c", updatedAt: morning, deviceId: nil)
        XCTAssertTrue(DoubaoWorkLocalUse.activeDates(conversations: [chat], localDeviceId: local, foreground: []).isEmpty,
                      "窗口一直在后台：别的设备问的，不算")
        let away = DateInterval(start: morning.addingTimeInterval(-3_600), end: morning.addingTimeInterval(-600))
        XCTAssertTrue(DoubaoWorkLocalUse.activeDates(conversations: [chat], localDeviceId: local, foreground: [away]).isEmpty,
                      "前台时段早就结束了，不算")
        let atDesk = DateInterval(start: morning.addingTimeInterval(-300), end: morning.addingTimeInterval(-30))
        XCTAssertEqual(DoubaoWorkLocalUse.activeDates(conversations: [chat], localDeviceId: local, foreground: [atDesk]),
                       [DailyAggregator.dateString(for: morning)],
                       "刚切走几十秒、对话列表才更新：时钟偏差内照样算")
    }

    // MARK: 读聊天库

    /// 日志文件里的一条记录（含拆成两段的）+ 表文件里 snappy 压缩的块，都要读出来。
    func testReadsConversationsFromLogAndCompressedTable() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatDB = dir.appendingPathComponent("Default/IndexedDB/chrome_doubaowork-chat_0.indexeddb.leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDB, withIntermediateDirectories: true)

        let task = conversation(id: "30000000000000001", updateTime: "1790231928", deviceId: local)
        let chat = conversation(id: "30000000000000002", updateTime: "1791348186", deviceId: nil)
        try logFile(records: [[0x01, 0x02] + task]).write(to: chatDB.appendingPathComponent("000029.log"))
        try tableFile(block: [0x09] + chat).write(to: chatDB.appendingPathComponent("000030.ldb"))
        // 拆段的记录：开头 + 结尾
        let split = conversation(id: "30000000000000003", updateTime: "1789120860", deviceId: local)
        try logFile(fragments: [Array(split[..<20]), Array(split[20...])]).write(to: chatDB.appendingPathComponent("000031.log"))

        let found = DoubaoWorkLocalUse.conversations(inChatDatabase: chatDB)
        XCTAssertEqual(Set(found.map(\.id)), ["30000000000000001", "30000000000000002", "30000000000000003"])
        XCTAssertEqual(found.first { $0.id == "30000000000000001" }?.deviceId, local)
        XCTAssertNil(found.first { $0.id == "30000000000000002" }?.deviceId)
        XCTAssertEqual(found.first { $0.id == "30000000000000002" }?.updatedAt, morning)
    }

    func testSnappyLiteralAndCopy() {
        // "abcd" 原样 + 回拷 4 字节（偏移 4）→ "abcdabcd"
        XCTAssertEqual(Snappy.decompress([8, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x01, 0x04]), Array("abcdabcd".utf8))
        XCTAssertNil(Snappy.decompress([8, 0x0C, 0x61]), "截断的块不能读出半截数据")
    }

    // MARK: 认定过的日期要自己记下来

    /// 聊天库只留每个对话最后一次更新时间：本机用过的那天，之后别处接着聊会把证据覆盖掉。
    func testRecognizedDatesSurviveChatDatabaseChanges() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatDB = dir.appendingPathComponent("Default/IndexedDB/chrome_doubaowork-chat_0.indexeddb.leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDB, withIntermediateDirectories: true)
        try #"{"aha":{"device":{"device_id":"\#(local)"}}}"#.write(
            to: dir.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
        let log = chatDB.appendingPathComponent("000029.log")
        try logFile(records: [conversation(id: "t", updateTime: "1791348186", deviceId: local)]).write(to: log)
        let cache = dir.appendingPathComponent("doubao-work-local.json")
        let day = DailyAggregator.dateString(for: morning)

        let store = DoubaoWorkLocalUseStore(fileURL: cache, dataDirectory: dir)
        let first = await store.activeDates(now: morning)
        XCTAssertEqual(first, [day])

        try FileManager.default.removeItem(at: log)
        let reopened = DoubaoWorkLocalUseStore(fileURL: cache, dataDirectory: dir)
        let again = await reopened.activeDates(now: morning)
        XCTAssertEqual(again, [day], "usageBar 重启、聊天库被改写后，那天照样算本机用过")
    }

    // MARK: 构造测试数据

    /// IndexedDB 里一个对话对象的 V8 序列化
    private func conversation(id: String, updateTime: String, deviceId: String?) -> [UInt8] {
        func str(_ s: String) -> [UInt8] { [0x22, UInt8(s.utf8.count)] + Array(s.utf8) }
        var bytes: [UInt8] = [0xFF, 0x0F, 0x6F]
        bytes += str("conversation_id") + str(id)
        bytes += str("update_time") + str(updateTime)
        bytes += str("device_reference") + [0x6F]
        if let deviceId { bytes += str("device_id") + str(deviceId) + [0x7B, 0x01] } else { bytes += [0x7B, 0x00] }
        bytes += [0x7B, 0x03]
        return bytes
    }

    private func logFile(records: [[UInt8]]) -> Data {
        Data(records.flatMap { [0, 0, 0, 0, UInt8($0.count & 0xFF), UInt8($0.count >> 8), 1] + $0 })
    }

    private func logFile(fragments: [[UInt8]]) -> Data {
        Data(fragments.enumerated().flatMap { k, f in
            [0, 0, 0, 0, UInt8(f.count & 0xFF), UInt8(f.count >> 8), k == 0 ? 2 : 4] + f
        })
    }

    /// 只有一个数据块的表文件：数据块用 snappy「原样字节」压缩
    private func tableFile(block raw: [UInt8]) -> Data {
        func varint(_ v: Int) -> [UInt8] {
            var v = v, out: [UInt8] = []
            while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            return out + [UInt8(v)]
        }
        let literal: [UInt8] = raw.count <= 60
            ? [UInt8((raw.count - 1) << 2)] : [60 << 2, UInt8(raw.count - 1)]
        let compressed = varint(raw.count) + literal + raw
        var file = compressed + [1, 0, 0, 0, 0]
        let handle = varint(0) + varint(compressed.count)
        let index = [0, 1] + varint(handle.count) + [0x6B] + handle + [0, 0, 0, 0, 1, 0, 0, 0]
        let indexOffset = file.count
        file += index + [0, 0, 0, 0, 0]
        var footer = varint(0) + varint(0) + varint(indexOffset) + varint(index.count)
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        footer += [0x57, 0xFB, 0x80, 0x8B, 0x24, 0x75, 0x47, 0xDB]
        return Data(file + footer)
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doubao-local-\(UUID().uuidString)", isDirectory: true)
    }
}
