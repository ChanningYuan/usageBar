import CryptoKit
import Foundation
import usageBarCore

/// 千问办公积分账单的一条记录。
///
/// `amount` 保留服务端符号：消耗为负数、奖励/充值为正数。usageBar 的周期消耗只汇总负数，
/// 因而“每日奖励”等入账不会抵扣当天真实消耗。
struct QwenWorkBillingRecord: Codable, Sendable, Equatable {
    enum Origin: String, Codable, Sendable {
        case billings
        case computer
    }

    let amount: Double
    let createdAt: Date
    let source: String
    let detail: String
    let origin: Origin
    /// 服务端若将来/部分环境返回稳定 id，优先用它识别可变账单行；当前实测为空。
    let serverId: String?

    var spent: Double { amount < 0 ? -amount : 0 }

    /// 当前接口没有公开会话 id。以服务端 id 优先，否则用不会随 amount 变化的字段组成稳定键。
    var identityKey: String {
        if let serverId, !serverId.isEmpty {
            return "\(origin.rawValue)|id|\(serverId)"
        }
        return "\(origin.rawValue)|\(createdAt.timeIntervalSince1970)|\(source)|\(detail)"
    }
}

/// 从可变账单行差分出的积分流水。`credits` 可为负数（服务端纠正/退款），以保证累计能回到真值。
struct QwenWorkCreditLedgerEntry: Codable, Sendable, Equatable {
    let credits: Double
    let occurredAt: Date
    let recordKey: String
    let origin: QwenWorkBillingRecord.Origin
}

struct QwenWorkCreditHistory: Sendable, Equatable {
    let ledger: [QwenWorkCreditLedgerEntry]
    /// true 表示磁盘上有可解码缓存，或本进程至少成功接收过一路账单响应。
    let isAvailable: Bool
}

/// 千问办公积分历史缓存。
///
/// 官网“用量明细”页本身也是同时读取：
/// - `GET /user/billings`：网页/钉钉等账单；
/// - `GET /user/billings/computer`：电脑端按日汇总。
///
/// 两个接口都返回完整历史，官网拿到后才在前端本地分页。这里保存两层数据：
/// 1. **当前行快照**按来源整批替换，绝不把旧金额和新金额同时计入；
/// 2. **积分差分流水**：同一会话的旧行 amount 增长时，只把增量记到本次观察时间。
///
/// 第 2 层不能省：实测同会话 10:39 的新扣减会继续累加在 created_at=10:01 的旧行上。
/// 若会话跨日/跨周，直接按旧 created_at 汇总会把新消耗算回旧周期；差分流水才能满足按周统计。
public actor QwenWorkBillingStore {
    public static let shared = QwenWorkBillingStore()

    private struct CacheFile: Codable {
        let version: Int
        let updatedAt: Date
        let accountFingerprint: String?
        let records: [QwenWorkBillingRecord]
        let ledger: [QwenWorkCreditLedgerEntry]
    }

    /// v1 只保存当前行；升级到 v2/v3 时把存量行按服务端 created_at 初始化进流水。
    private struct LegacyCacheFile: Codable {
        let version: Int
        let updatedAt: Date
        let records: [QwenWorkBillingRecord]
    }

    private enum FetchResult {
        case success([QwenWorkBillingRecord])
        case auth
        case failure
    }

    private static let billingsEndpoint = "https://qwenwork.cn/user/billings"
    private static let computerEndpoint = "https://qwenwork.cn/user/billings/computer"

    private let fileURL: URL
    private var accountFingerprint: String?
    private var cachedToken: String?
    private var records: [QwenWorkBillingRecord] = []
    private var ledger: [QwenWorkCreditLedgerEntry] = []
    private var hasSynced = false
    private var loaded = false
    private var refreshInFlight = false
    private var lastRefreshAt: Date?

    public static var defaultPath: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("usageBar", isDirectory: true)
            .appendingPathComponent("qwen-work-billings.json")
    }

    init(fileURL: URL = QwenWorkBillingStore.defaultPath) {
        self.fileURL = fileURL
    }

    /// 只清内存里的登录 token；账单历史是用户要求保留的本地缓存，不随“重置授权”删除。
    public func clearAuthCache() {
        cachedToken = nil
    }

    /// 返回从账单快照差分出的本地流水。首次调用会从磁盘恢复，离线时仍可按周期查看。
    func cachedLedger() -> [QwenWorkCreditLedgerEntry] {
        loadIfNeeded()
        return ledger
    }

    func cachedHistory() -> QwenWorkCreditHistory {
        loadIfNeeded()
        return QwenWorkCreditHistory(ledger: ledger, isAvailable: hasSynced)
    }

    /// 刷新两路账单。任一路失败都保留该路旧缓存；另一路成功仍会独立更新。
    ///
    /// 30 秒内的重复调用直接复用缓存，避免“打开详情 + 主刷新”同时触发两次请求。
    @discardableResult
    public func refresh(now: Date = Date(), force: Bool = false) async -> Bool {
        loadIfNeeded()
        if !force, let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < 30 {
            return true
        }
        // actor 在网络 await 期间可重入；显式拦住并发刷新，避免同一轮发两组请求。
        guard !refreshInFlight else { return true }
        refreshInFlight = true
        defer { refreshInFlight = false }

        if let token = cachedToken {
            let result = await fetchAll(token: token)
            if result.authFailed {
                cachedToken = nil
            } else {
                return apply(
                    result,
                    now: now,
                    accountFingerprint: Self.accountFingerprint(from: token)
                )
            }
        }

        guard let token = acquireToken() else { return false }
        cachedToken = token
        let result = await fetchAll(token: token)
        if result.authFailed { cachedToken = nil }
        return apply(
            result,
            now: now,
            accountFingerprint: Self.accountFingerprint(from: token)
        )
    }

    // MARK: - 网络与认证

    private struct CombinedFetch {
        let billings: FetchResult
        let computer: FetchResult

        var authFailed: Bool {
            if case .auth = billings { return true }
            if case .auth = computer { return true }
            return false
        }
    }

    private func fetchAll(token: String) async -> CombinedFetch {
        async let billings = request(
            endpoint: Self.billingsEndpoint,
            origin: .billings,
            token: token
        )
        async let computer = request(
            endpoint: Self.computerEndpoint,
            origin: .computer,
            token: token
        )
        return await CombinedFetch(billings: billings, computer: computer)
    }

    private func request(
        endpoint: String,
        origin: QwenWorkBillingRecord.Origin,
        token: String
    ) async -> FetchResult {
        guard let url = URL(string: endpoint) else { return .failure }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("usageBar", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure }
            switch http.statusCode {
            case 200: break
            case 401, 403: return .auth
            default: return .failure
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) else {
                return .failure
            }
            let parsed: [QwenWorkBillingRecord]?
            switch origin {
            case .billings: parsed = Self.parseBillings(root)
            case .computer: parsed = Self.parseComputer(root)
            }
            return parsed.map(FetchResult.success) ?? .failure
        } catch {
            return .failure
        }
    }

    /// QwenWorkCN Electron safeStorage：auth-v2.dat / auth.dat +
    /// 钥匙串 `QwenWorkCN Safe Storage`。解密算法与 QoderWork 完全相同，复用已审计实现。
    private func acquireToken() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenWorkCN")
        let files = ["auth-v2.dat", "auth.dat"].map { dir.appendingPathComponent($0) }
        guard files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let key = QoderRateLimitReader.deriveKey(service: "QwenWorkCN Safe Storage")
        else { return nil }

        for url in files {
            guard let encrypted = try? Data(contentsOf: url),
                  let decrypted = QoderRateLimitReader.decrypt(encrypted, key: key),
                  let object = try? JSONSerialization.jsonObject(with: decrypted),
                  let token = QoderRateLimitReader.findToken(in: object),
                  !token.isEmpty
            else { continue }
            return token
        }
        return nil
    }

    // MARK: - 响应解析

    /// `/user/billings` 的兼容解析，与官网前端的 data/items/billings/records 解包顺序一致。
    static func parseBillings(_ root: Any) -> [QwenWorkBillingRecord]? {
        guard let rows = unwrapRows(root) else { return nil }
        return rows.compactMap { row in
            guard let amount = number(row["amount"]),
                  let rawDate = row["created_at"] as? String,
                  let createdAt = parseDate(rawDate)
            else { return nil }
            let detailObject = row["detail"] as? [String: Any]
            let title = nonEmpty(detailObject?["title"] as? String) ?? "—"
            let rawSource = firstNonEmpty([
                row["consume_source"],
                row["client_name"],
                row["client_type"],
                row["platform"],
                row["source"],
                detailObject?["source"],
            ])
            let source = rawSource ?? (amount < 0 ? "网页版" : "—")
            let serverId = firstNonEmpty([
                row["id"],
                row["billing_id"],
                row["transaction_id"],
                row["order_id"],
            ])
            return QwenWorkBillingRecord(
                amount: amount,
                createdAt: createdAt,
                source: source,
                detail: title,
                origin: .billings,
                serverId: serverId
            )
        }
    }

    /// `/user/billings/computer`：`daily_breakdown[].amount` 在官网统一转成负数（消耗）。
    /// data 为 null 表示当前没有电脑端账单，是合法空集而非解析错误。
    static func parseComputer(_ root: Any) -> [QwenWorkBillingRecord]? {
        if root is NSNull { return [] }
        var current: Any = root
        for _ in 0..<2 {
            guard let object = current as? [String: Any] else { break }
            if let rows = object["daily_breakdown"] as? [[String: Any]] {
                let detailObject = object["detail"] as? [String: Any]
                let title = nonEmpty(detailObject?["title"] as? String) ?? "电脑端用量"
                return rows.compactMap { row in
                    guard let rawDate = row["date"] as? String,
                          let createdAt = parseDate(rawDate),
                          let rawAmount = number(row["amount"])
                    else { return nil }
                    return QwenWorkBillingRecord(
                        amount: rawAmount > 0 ? -rawAmount : rawAmount,
                        createdAt: createdAt,
                        source: "电脑版",
                        detail: title,
                        origin: .computer,
                        serverId: rawDate
                    )
                }
            }
            guard let data = object["data"] else { return nil }
            if data is NSNull { return [] }
            current = data
        }
        return nil
    }

    private static func unwrapRows(_ root: Any) -> [[String: Any]]? {
        var current: Any = root
        for _ in 0..<3 {
            if current is NSNull { return [] }
            if let rows = current as? [[String: Any]] { return rows }
            guard let object = current as? [String: Any] else { return nil }
            let next = object["data"]
                ?? object["items"]
                ?? object["billings"]
                ?? object["records"]
            guard let next else { return nil }
            current = next
        }
        if current is NSNull { return [] }
        return current as? [[String: Any]]
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISODateParser.parse(value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonEmpty(_ values: [Any?]) -> String? {
        for case let value as String in values {
            if let value = nonEmpty(value) { return value }
        }
        return nil
    }

    /// JWT 只取稳定账号标识并立即哈希；token、email、user_id 都不会写入缓存。
    /// 旧版/非 JWT token 返回 nil，此时保持向后兼容但不做账号切换判断。
    static func accountFingerprint(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let identifier = firstNonEmpty([
                  object["user_id"],
                  object["sub"],
                  object["email"],
              ])
        else { return nil }
        let digest = SHA256.hash(data: Data("qwen-work|\(identifier)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 缓存替换

    private func apply(
        _ result: CombinedFetch,
        now: Date,
        accountFingerprint incomingAccount: String?
    ) -> Bool {
        let hasSuccess: Bool = {
            if case .success = result.billings { return true }
            if case .success = result.computer { return true }
            return false
        }()
        guard hasSuccess else { return false }

        // 只有拿到至少一路成功响应后才切换账号，网络失败绝不能误清本地历史。
        selectAccount(incomingAccount)

        var changed = false
        if case .success(let fetched) = result.billings {
            replace(origin: .billings, with: fetched, observedAt: now)
            changed = true
        }
        if case .success(let fetched) = result.computer {
            replace(origin: .computer, with: fetched, observedAt: now)
            changed = true
        }
        guard changed else { return false }
        lastRefreshAt = now
        persist(updatedAt: now)
        return true
    }

    /// 切换千问账号时清空上一账号的行与差分流水，防止跨账号合计。
    /// 首次从 v1/v2 缓存升级时账号未知，仅补 fingerprint，不丢已有历史。
    func selectAccount(_ incoming: String?) {
        guard let incoming else { return }
        if let current = accountFingerprint, current != incoming {
            records.removeAll()
            ledger.removeAll()
        }
        accountFingerprint = incoming
    }

    /// 同来源整批替换，同时把 amount 变化转成一条增量流水：
    /// - 新行：完整扣减归到服务端 created_at；
    /// - 已见行：新旧 spend 差归到 observedAt，解决跨日/跨周会话仍沿用旧时间的问题；
    /// - 数值未变：不写流水。
    func replace(
        origin: QwenWorkBillingRecord.Origin,
        with fetched: [QwenWorkBillingRecord],
        observedAt: Date = Date()
    ) {
        loadIfNeeded()
        hasSynced = true
        let previous = Dictionary(
            records.filter { $0.origin == origin }.map { ($0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // 接口理论上返回完整历史；仍以已有流水合计作第二基线，防止某行短暂缺席后
        // 再出现时被当成新行重复计费。
        var accumulated = Dictionary(grouping: ledger, by: \.recordKey)
            .mapValues { $0.reduce(0.0) { $0 + $1.credits } }
        for record in fetched {
            let wasSeen = previous[record.identityKey] != nil
                || accumulated[record.identityKey] != nil
            let oldSpent = previous[record.identityKey]?.spent
                ?? accumulated[record.identityKey]
                ?? 0
            let delta = record.spent - oldSpent
            guard abs(delta) > 0.000_000_1 else { continue }
            ledger.append(QwenWorkCreditLedgerEntry(
                credits: delta,
                occurredAt: wasSeen ? observedAt : record.createdAt,
                recordKey: record.identityKey,
                origin: origin
            ))
            accumulated[record.identityKey] = oldSpent + delta
        }
        records.removeAll { $0.origin == origin }
        records.append(contentsOf: fetched)
        records.sort { $0.createdAt > $1.createdAt }
        persist(updatedAt: observedAt)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cache = try? decoder.decode(CacheFile.self, from: data),
           cache.version == 2 || cache.version == 3 {
            hasSynced = true
            accountFingerprint = cache.accountFingerprint
            records = cache.records
            ledger = cache.ledger
            lastRefreshAt = cache.updatedAt
            return
        }
        if let legacy = try? decoder.decode(LegacyCacheFile.self, from: data),
           legacy.version == 1 {
            hasSynced = true
            records = legacy.records
            ledger = legacy.records.compactMap { record in
                guard record.spent > 0 else { return nil }
                return QwenWorkCreditLedgerEntry(
                    credits: record.spent,
                    occurredAt: record.createdAt,
                    recordKey: record.identityKey,
                    origin: record.origin
                )
            }
            lastRefreshAt = legacy.updatedAt
        }
    }

    private func persist(updatedAt: Date) {
        let file = CacheFile(
            version: 3,
            updatedAt: updatedAt,
            accountFingerprint: accountFingerprint,
            records: records,
            ledger: ledger
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
