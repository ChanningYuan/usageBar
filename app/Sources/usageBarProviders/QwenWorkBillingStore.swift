import CryptoKit
import Foundation
import usageBarCore

/// 千问办公积分账单的一条记录。
///
/// `amount` 保留服务端符号：消耗为负数、奖励/充值为正数。
///
/// ⛔ **负数 ≠ 消耗**（2026-08-04 探针实证，别再改回去）：账单 `type` 有三种——
/// `对话`（真消耗）/ `过期`（当天没花完的赠送额度作废）/ `奖励`（入账）。**「过期」也是负数**。
/// 初版拿「负数即消耗」当判据，导致今日消耗虚报 100（真实 0）、历史虚增 3.6 倍
/// （过期 −988.50 混进真实消耗 −274.49）。
///
/// 判据必须是**白名单** `type == "对话"`，别用排除法排掉已知的「过期」「奖励」——
/// 厂商将来新增一种负数类型（退款 / 扣罚…）会再次被误计。
/// ⚠️ 官方「已使用」页把过期行也列在里面，所以 usageBar 的已用会**小于**官方列表，这是预期差异不是漏算。
/// 详见 `docs/0804-千问办公接入/千问办公接入-spec.md` §1c。
struct QwenWorkBillingRecord: Codable, Sendable, Equatable {
    enum Origin: String, Codable, Sendable {
        case billings
        case computer
    }

    /// 唯一算作「积分消耗」的账单类型。
    static let consumptionType = "对话"

    let amount: Double
    let createdAt: Date
    let source: String
    let detail: String
    let origin: Origin
    /// 服务端若将来/部分环境返回稳定 id，优先用它识别可变账单行；当前实测为空。
    let serverId: String?
    /// 服务端账单类型：`对话` / `过期` / `奖励`。老缓存没有这个字段，故 v4 整体弃用老缓存（见 `loadIfNeeded`）。
    let type: String?

    /// 是否真实对话消耗。`/user/billings/computer` 的按日汇总行没有 type，解析时显式补成 `对话`
    /// （它按定义就是电脑端用量）。
    var isConsumption: Bool { type == Self.consumptionType }

    var spent: Double { isConsumption && amount < 0 ? -amount : 0 }

    /// 当前接口没有公开会话 id。以服务端 id 优先，否则用不会随 amount 变化的字段组成稳定键。
    ///
    /// ⚠️ **这个键不保证唯一**：同一秒可能有多条账单，而它们的 source / detail 也完全一样
    /// （实测 13:59:21 两条、13:08 也是同分钟多条）。去重与差分必须用 `indexedKeys` 加组内序号，
    /// 别直接拿它当字典 key——那会让同秒行互相覆盖，差分永远不收敛（见 `indexedKeys` 的注释）。
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

/// 主列表额度药丸要的两个数：剩余可用（接口直给）+ 当日真实消耗（账单汇总）。
///
/// **为什么不是百分比**：官方「我的积分」页只有「剩余可用」，没有「总额」的概念；分母只能从流水反推、
/// 且每天都在变（平时每日赠 100、当天搞活动就是 500），显示出来会跳得没道理、和官方也对不上账。
/// 官方自己的分组还自相矛盾（剩余可用 2,437.02，但「每日 500 + 其他 0」只有 500）。
/// 所以只取**官方页面上存在、且能逐位对上的数**。详见 spec §2a。
public struct QwenWorkQuota: Sendable, Equatable {
    public let balance: Double?
    public let todaySpent: Double
    public let error: RateLimitError?
}

/// 千问办公积分账单缓存 + 余额。
///
/// 三路数据（2026-08-04 探针实测 22 条路径后定的口径，见 spec §1a）：
/// - `GET /user/billings`：**全部**积分流水（奖励 / 过期 / 对话三种 type），服务端一次返回完整历史；
/// - `GET /user/balance`：当前剩余可用（= 官方「我的积分」页大字，逐位一致）；
/// - `GET /user/billings/computer`：电脑端按日汇总。**本机实测恒为 null**（桌面消耗其实混在主账单里、
///   靠 `source=desktop` 区分），但保留调用——不排除其它账号/版本上有数据，去掉会导致那些账号漏算。
///
/// 另外两条已知不可用：`/user/quota` 返回 403 `Client type is not allowed`（试过 5 种 client 头，
/// 疑似网页端专用）；其余 16 条候选路径全 404，且分页/过滤参数一律无效。
///
/// 缓存保存两层数据：
/// 1. **当前行快照**按来源整批替换，绝不把旧金额和新金额同时计入；
/// 2. **积分差分流水**：同一会话的旧行 amount 增长时，只把增量记到本次观察时间。
///
/// 第 2 层不能省：实测同会话 10:39 的新扣减会继续累加在 created_at=10:01 的旧行上。
/// 若会话跨日/跨周，直接按旧 created_at 汇总会把新消耗算回旧周期；差分流水才能满足按周统计。
public actor QwenWorkBillingStore {
    public static let shared = QwenWorkBillingStore()

    /// 当前缓存版本。
    ///
    /// ⚠️ 两次**不兼容**升级，都是流水本身算错了、无法就地修：
    /// - v3 → v4：v3 用「负数即消耗」，把「积分过期」记成了消耗，而 v3 的行没存 `type`；
    /// - v4 → v5：v4 的键在同秒多行时相撞，每次刷新都会多写一笔幽灵流水（见 `indexedKeys`）。
    ///
    /// 服务端每次都返回完整历史，所以弃用旧缓存重拉即可——代价只是那些「旧行金额增长」的增量
    /// 会退回按服务端时间归因，会自愈。
    private static let cacheVersion = 5

    private struct CacheFile: Codable {
        let version: Int
        let updatedAt: Date
        let accountFingerprint: String?
        let records: [QwenWorkBillingRecord]
        let ledger: [QwenWorkCreditLedgerEntry]
        /// 剩余可用积分（`/user/balance`）。离线时按最后一次成功值展示。
        let balance: Double?
    }

    private enum FetchResult {
        case success([QwenWorkBillingRecord])
        case auth
        case failure
    }

    private static let billingsEndpoint = "https://qwenwork.cn/user/billings"
    private static let computerEndpoint = "https://qwenwork.cn/user/billings/computer"
    private static let balanceEndpoint = "https://qwenwork.cn/user/balance"

    private let fileURL: URL
    private var accountFingerprint: String?
    private var cachedToken: String?
    private var records: [QwenWorkBillingRecord] = []
    private var ledger: [QwenWorkCreditLedgerEntry] = []
    private var balance: Double?
    private var hasSynced = false
    private var loaded = false
    private var refreshInFlight = false
    private var lastRefreshAt: Date?
    private var lastError: RateLimitError?

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

    /// 主列表额度药丸的数据源：剩余可用 + **当日**真实对话消耗。
    ///
    /// 当日消耗从差分流水汇总（流水本身已只含 `type == 对话`，见 `replace`）。
    public func quota(now: Date = Date()) -> QwenWorkQuota {
        loadIfNeeded()
        let today = DailyAggregator.dateString(for: now)
        let spent = ledger
            .filter { DailyAggregator.dateString(for: $0.occurredAt) == today }
            .reduce(0.0) { $0 + $1.credits }
        return QwenWorkQuota(
            balance: balance,
            todaySpent: max(0, spent),
            // 有缓存就先把数显示出来；只有「从没成功过」才把错误抛给 UI。
            error: hasSynced ? nil : lastError
        )
    }

    /// 展示用格式化："2,437.02"（两位小数 + 千分位，与官方「我的积分」页一致）。
    public static func formatCredits(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 刷新账单与余额。任一路失败都保留该路旧缓存；其余路成功仍会独立更新。
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

        guard let token = acquireToken() else {
            lastError = .credentialUnavailable
            return false
        }
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
        /// 剩余可用；nil = 这一路失败（保留上次缓存值，不清零——余额清零会被误读成"额度用光了"）
        let balance: Double?

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
        async let balance = requestBalance(token: token)
        return await CombinedFetch(billings: billings, computer: computer, balance: balance)
    }

    /// `GET /user/balance` → `data.balance`。这就是官方「我的积分 → 剩余可用」那个大字。
    private func requestBalance(token: String) async -> Double? {
        guard let url = URL(string: Self.balanceEndpoint) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("usageBar", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return Self.parseBalance(root)
    }

    /// 兼容 `{"data":{"balance":…}}` 与直给 `{"balance":…}`。
    static func parseBalance(_ root: Any) -> Double? {
        guard let object = root as? [String: Any] else { return nil }
        if let value = number(object["balance"]) { return value }
        guard let data = object["data"] as? [String: Any] else { return nil }
        return number(data["balance"])
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
                serverId: serverId,
                // ⛔ 这个字段是「负数是不是消耗」的唯一判据，别省（见 QwenWorkBillingRecord 头注）
                type: nonEmpty(row["type"] as? String)
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
                        serverId: rawDate,
                        // 这一路是「电脑端用量」按日汇总，按定义就是对话消耗；服务端不带 type，显式补上，
                        // 否则会被新的白名单判据当成非消耗而漏算（本机该接口恒 null，但别的账号可能有）。
                        type: QwenWorkBillingRecord.consumptionType
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
        guard hasSuccess else {
            lastError = result.authFailed ? .credentialUnavailable : .network
            return false
        }

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
        // 余额这一路失败时保留上次的值：显示旧余额比显示 0 好，0 会被读成"额度用光了"。
        if let fetched = result.balance { balance = fetched }
        lastError = nil
        lastRefreshAt = now
        persist(updatedAt: now)
        return true
    }

    /// 切换千问账号时清空上一账号的行、差分流水与余额，防止跨账号合计。
    /// 账号未知时仅补 fingerprint，不丢已有历史。
    func selectAccount(_ incoming: String?) {
        guard let incoming else { return }
        if let current = accountFingerprint, current != incoming {
            records.removeAll()
            ledger.removeAll()
            balance = nil
        }
        accountFingerprint = incoming
    }

    /// 同来源整批替换，同时把 amount 变化转成一条增量流水：
    /// - 新行：完整扣减归到服务端 created_at；
    /// - 已见行：新旧 spend 差归到 observedAt，解决跨日/跨周会话仍沿用旧时间的问题；
    /// - 数值未变：不写流水。
    /// 给账单行生成**真正唯一**的键：`identityKey` + 组内序号。
    ///
    /// ⛔ 为什么必须加序号（2026-08-04 实测抓到的持续虚增 bug）：服务端同一秒会返回多条账单，
    /// 它们的 created_at / source / detail 完全一样 → `identityKey` 相撞。相撞后：
    /// - `previous` 字典只留下第一条（`uniquingKeysWith: first`）；
    /// - 循环到第二条时拿第一条的金额当基线，差出一个**非零** delta 并写进流水；
    /// - 下一次刷新重复同样的计算 → **每刷新一次就多记一笔**，永远不收敛。
    ///
    /// 实测现场：一条 7-30 的旧行被写了 5 遍、每遍 0.3847，把当天总额从 2.67 顶到 4.59。
    ///
    /// 序号按**服务端返回顺序**编（所以 `records` 不再排序，见 `replace` 末尾）；第 0 条沿用原 key，
    /// 让已有流水的 recordKey 保持可对应。
    static func indexedKeys(_ records: [QwenWorkBillingRecord]) -> [String] {
        var seen: [String: Int] = [:]
        return records.map { record in
            let n = seen[record.identityKey, default: 0]
            seen[record.identityKey] = n + 1
            return n == 0 ? record.identityKey : "\(record.identityKey)#\(n)"
        }
    }

    func replace(
        origin: QwenWorkBillingRecord.Origin,
        with fetched: [QwenWorkBillingRecord],
        observedAt: Date = Date()
    ) {
        loadIfNeeded()
        hasSynced = true
        let previousRecords = records.filter { $0.origin == origin }
        let previous = Dictionary(
            uniqueKeysWithValues: zip(Self.indexedKeys(previousRecords), previousRecords)
        )
        // 接口理论上返回完整历史；仍以已有流水合计作第二基线，防止某行短暂缺席后
        // 再出现时被当成新行重复计费。
        var accumulated = Dictionary(grouping: ledger, by: \.recordKey)
            .mapValues { $0.reduce(0.0) { $0 + $1.credits } }
        for (key, record) in zip(Self.indexedKeys(fetched), fetched) {
            let wasSeen = previous[key] != nil || accumulated[key] != nil
            let oldSpent = previous[key]?.spent ?? accumulated[key] ?? 0
            let delta = record.spent - oldSpent
            guard abs(delta) > 0.000_000_1 else { continue }
            ledger.append(QwenWorkCreditLedgerEntry(
                credits: delta,
                occurredAt: wasSeen ? observedAt : record.createdAt,
                recordKey: key,
                origin: origin
            ))
            accumulated[key] = oldSpent + delta
        }
        records.removeAll { $0.origin == origin }
        records.append(contentsOf: fetched)
        // ⚠️ 不排序：序号编在服务端返回顺序上，重排会让同秒行的序号在两次刷新间错位
        // （Swift 的 sort 不保证稳定），差分基线就又对不上了。
        persist(updatedAt: observedAt)
    }

    /// 只接受当前版本的缓存。
    ///
    /// ⚠️ **不做 v1–v4 迁移是刻意的**：v1–v3 的流水把「积分过期」算成了消耗（且行里没有 `type` 可供判断），
    /// v4 的流水含同秒撞键产生的幽灵条目——两种坏数据都无法就地识别并剔除。
    /// 服务端每次返回完整历史，弃用旧缓存下一次刷新就全回来了；保留错数据只会一直错下去。
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(CacheFile.self, from: data),
              cache.version == Self.cacheVersion
        else { return }
        hasSynced = true
        accountFingerprint = cache.accountFingerprint
        records = cache.records
        ledger = cache.ledger
        balance = cache.balance
        lastRefreshAt = cache.updatedAt
    }

    private func persist(updatedAt: Date) {
        let file = CacheFile(
            version: Self.cacheVersion,
            updatedAt: updatedAt,
            accountFingerprint: accountFingerprint,
            records: records,
            ledger: ledger,
            balance: balance
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
