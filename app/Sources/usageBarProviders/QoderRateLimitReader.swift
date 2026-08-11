import Foundation
import Security
import CommonCrypto
import SQLite3
import usageBarCore

/// Qoder 账号额度读取（v0.3.24 单账号，v0.3.29 起按凭证分账号，issue #4）。
///
/// **额度值永远走官方 API**（`GET https://openapi.qoder.sh/api/v2/quota/usage`，2026-07-14 探针实证，见 spec §4.3）：
/// ```json
/// {"userType":"personal_standard","usageType":"credits","totalUsagePercentage":37.0,
///  "userQuota":{"total":5000,"used":1850,"remaining":3150,"percentage":37,"unit":"credits"},
///  "expiresAt":<ms>}
/// ```
///
/// 凭证来源两处（各解各的，issue #4：外部用户实测两端可以登录**不同账号**，
/// 「CLI / Work / IDE 共用一份额度」只在同账号时成立，不能拿 Work 的额度标成 IDE 的）：
/// 1. **QoderWork**：`…/QoderWork/auth-v2.dat` → 钥匙串 `QoderWork Safe Storage` 解 safeStorage(v10)；
/// 2. **Qoder IDE**：`…/Qoder/User/globalStorage/state.vscdb` 里 `secret://aicoding.auth.userInfo`
///    （值是 `{"type":"Buffer","data":[v10…]}`）→ 钥匙串 `Qoder Safe Storage` 解同款 safeStorage。
///
/// 每档先做**免费的存在性检查**（文件/DB 在不在），命中才碰对应钥匙串 → 各弹一次；解出的凭证内存缓存跨刷新复用。
/// （Qoder CLI `~/.qoder/.auth/user` 用原生二进制里的固定密钥加密，机器码派生试过均不中、破解需反汇编 → 见调研 §Qoder降级，暂缓；
/// CLI 行的额度跟随 QoderWork 账号，见调度层 `storeQoder`。）
public struct QoderRateLimitReader {
    public init() {}

    /// Qoder 全家桶三个 provider 实例共享同一份账号级快照
    public static let providerIds = ["qoder-cli", "qoder-work", "qoder-ide"]
    private static let endpoint = "https://openapi.qoder.sh/api/v2/quota/usage"

    private var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// ⚠️ 解密后凭证内存缓存（跨刷新复用）——不能每次刷新都读钥匙串解密，否则每 10 分钟弹一次授权框。
    /// Work / IDE 分来源各存各的（issue #4：两端可能登录不同账号）。
    nonisolated(unsafe) private static var cachedWork: Credential?
    nonisolated(unsafe) private static var cachedIde: Credential?

    /// 取消授权/重置时清缓存 → 下次读重新解密（重新授权）
    public static func clearCache() { cachedWork = nil; cachedIde = nil }

    /// token + 账号指纹（用于判断 Work / IDE 是否同一账号）
    typealias Credential = (token: String, account: String)

    private enum Source { case work, ide }

    /// 按凭证分账号采集（issue #4）。返回 1 或 2 个快照：
    /// - 仅一份凭证登录，或双登录但**账号指纹相同** → 1 个「代表账号」快照（providerId "qoder-work"），
    ///   调度层复制到三个 qoder 实例——即原有行为；
    /// - QoderWork 与 Qoder IDE 登录了**不同账号** → 2 个快照各查各的（"qoder-work" / "qoder-ide"），
    ///   行标签与数据来源账号对齐，不再把 Work 账号的额度标成 "Qoder (IDE)"。
    public func readAll(now: Date = Date()) async -> [RateLimitSnapshot] {
        let work = credential(.work)
        let ide = credential(.ide)
        if let w = work, let i = ide, w.account != i.account {
            return [await readSource(.work, providerId: "qoder-work", now: now),
                    await readSource(.ide, providerId: "qoder-ide", now: now)]
        }
        if work != nil { return [await readSource(.work, providerId: "qoder-work", now: now)] }
        if ide != nil { return [await readSource(.ide, providerId: "qoder-work", now: now)] }
        return [RateLimitSnapshot(providerId: "qoder-work", windows: [], capturedAt: now,
                                  error: .credentialUnavailable)]
    }

    // MARK: - 凭证获取（分来源，带缓存）

    /// 取某来源凭证；命中内存缓存则不碰钥匙串（不弹框）。未登录/解不出返回 nil。
    private func credential(_ s: Source) -> Credential? {
        switch s {
        case .work:
            if let c = Self.cachedWork { return c }
            let c = credentialFromQoderWork(); Self.cachedWork = c; return c
        case .ide:
            if let c = Self.cachedIde { return c }
            let c = credentialFromQoderIDE(); Self.cachedIde = c; return c
        }
    }

    /// 某来源查一次额度；401 时清缓存重新解密（用户重新登录后 token 变了）、换到新 token 才重试一次。
    private func readSource(_ s: Source, providerId: String, now: Date) async -> RateLimitSnapshot {
        guard let c = credential(s) else {
            return RateLimitSnapshot(providerId: providerId, windows: [], capturedAt: now,
                                     error: .credentialUnavailable)
        }
        let snap = await request(token: c.token, providerId: providerId, now: now)
        guard snap.error == .credentialUnavailable else { return snap }
        switch s { case .work: Self.cachedWork = nil; case .ide: Self.cachedIde = nil }
        guard let fresh = credential(s), fresh.token != c.token else { return snap }
        return await request(token: fresh.token, providerId: providerId, now: now)
    }

    /// A 档 · QoderWork：解 auth-v2.dat / auth.dat（钥匙串 `QoderWork Safe Storage`）
    private func credentialFromQoderWork() -> Credential? {
        let dir = appSupport.appendingPathComponent("QoderWork")
        let files = ["auth-v2.dat", "auth.dat"].map { dir.appendingPathComponent($0) }
        guard files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let key = Self.deriveKey(service: "QoderWork Safe Storage") else { return nil }
        for url in files {
            guard let enc = try? Data(contentsOf: url),
                  let dec = Self.decrypt(enc, key: key),
                  let obj = try? JSONSerialization.jsonObject(with: dec) as? [String: Any] else { continue }
            if let t = obj["token"] as? String, !t.isEmpty {
                return (t, Self.accountFingerprint(in: obj, token: t))
            }
        }
        return nil
    }

    /// B 档 · Qoder IDE：vscdb `secret://aicoding.auth.userInfo`（钥匙串 `Qoder Safe Storage`）
    private func credentialFromQoderIDE() -> Credential? {
        let db = appSupport.appendingPathComponent("Qoder/User/globalStorage/state.vscdb").path
        // 免费检查：DB 在不在 + 有没有 userInfo（读明文 vscdb，不碰钥匙串）
        guard FileManager.default.fileExists(atPath: db),
              let bufferJSON = Self.readVscdbValue(db: db, key: "secret://aicoding.auth.userInfo"),
              let enc = Self.bytesFromNodeBuffer(bufferJSON),
              let key = Self.deriveKey(service: "Qoder Safe Storage"),
              let dec = Self.decrypt(enc, key: key),
              let obj = try? JSONSerialization.jsonObject(with: dec),
              let t = Self.findToken(in: obj) else { return nil }
        return (t, Self.accountFingerprint(in: obj, token: t))
    }

    // MARK: - 账号指纹（issue #4：判断 Work 与 IDE 是否同一账号）

    /// 判同优先级：JWT 的用户标识（sub/uid，最标准）→ 凭证 JSON 里的账号字段 → 退回 token 本身。
    /// 判不出宁可当**不同账号**分开查——方向安全：同账号被误分只是多查一次、两行数字相同；
    /// 不同账号被误合才会重现「标签与数据来源不一致」。
    static func accountFingerprint(in obj: Any, token: String) -> String {
        if let sub = jwtClaim(["sub", "uid", "userId", "user_id"], in: token) { return sub }
        let keys = ["uid", "userId", "user_id", "accountId", "account_id", "email", "phone"]
        if let hit = findString(keys: keys, in: obj) { return hit }
        return token
    }

    /// JWT（三段 base64url 拼接的令牌）payload 里取第一个命中的 claim；不是 JWT 返回 nil。
    static func jwtClaim(_ keys: [String], in token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for k in keys {
            if let s = obj[k] as? String, !s.isEmpty { return s }
            if let n = obj[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    /// 递归找第一个命中的账号字段（遍历方式同 findToken）
    static func findString(keys: [String], in obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            for k in keys {
                if let s = dict[k] as? String, !s.isEmpty { return s }
                if let n = dict[k] as? NSNumber { return n.stringValue }
            }
            for v in dict.values {
                if let found = findString(keys: keys, in: v) { return found }
            }
        } else if let arr = obj as? [Any] {
            for v in arr {
                if let found = findString(keys: keys, in: v) { return found }
            }
        }
        return nil
    }

    private func request(token tok: String, providerId: String, now: Date) async -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: providerId, windows: [], capturedAt: now, error: e)
        }
        guard let url = URL(string: Self.endpoint) else { return fail(.network) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Qoder", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return fail(.network) }
            switch http.statusCode {
            case 200: break
            case 401, 403: return fail(.credentialUnavailable)
            default: return fail(.network)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return fail(.network)
            }
            return Self.snapshot(fromQuota: obj, now: now, providerId: providerId)
        } catch {
            return fail(.network)
        }
    }

    /// 200 响应体 → 快照。静态纯函数，单测直接喂 personal / teams 两种账号的真实返回。
    /// 字段语义与坑（percentage 双量纲 / orgResourcePackage / expiresAt 归属）
    /// 见 KB `docs/0715-QoderTeams额度修复/Qoder额度API实录.md`。
    static func snapshot(fromQuota obj: [String: Any], now: Date,
                         providerId: String = "qoder-work") -> RateLimitSnapshot {
        let plan = obj["userType"] as? String   // API 响应自带 userType，无需本地兜底
        let quota = obj["userQuota"] as? [String: Any]
        let total = (quota?["total"] as? NSNumber)?.doubleValue ?? 0
        if total <= 0 {
            // 免费版（Community）无信用点额度概念
            return RateLimitSnapshot(providerId: providerId, windows: [],
                                     capturedAt: now, error: .noQuotaData)
        }
        let used = (quota?["used"] as? NSNumber)?.doubleValue ?? 0
        // ⚠️ 不能信 API 的 percentage 字段——同一字段两种量纲：personal 账号回 0–100（37 = 37%），
        // teams 账号回 0–1（1.0 = 100%，2026-07-15 同事 teams 实测，用满的席位显示成了 1%）。
        // used/total 两种账号语义一致，自己算。
        let pct = min(100, max(0, used / total * 100))
        let resets = parseExpiresAt(obj["expiresAt"])   // 顶层唯一，归属套餐的月度刷新
        // teams 席位配额随组织套餐走，标「套餐」和 Qoder 官方文案对齐；personal 仍叫「月」
        let seatLabel = plan == "teams" ? "套餐" : "月"
        var windows = [RateLimitWindow(kind: "monthly", label: seatLabel, usedPercent: pct,
                                       resetsAt: resets,
                                       detail: RateLimitWindow.usedOfTotal(used, total),
                                       used: used, total: total)]
        // teams 独有：组织资源包（购买制点数池，无重置时间，Qoder 官方界面也不给刷新日期）
        if let pack = obj["orgResourcePackage"] as? [String: Any],
           let cap = (pack["cap"] as? NSNumber)?.doubleValue, cap > 0 {
            let pUsed = (pack["used"] as? NSNumber)?.doubleValue ?? 0
            windows.append(RateLimitWindow(kind: "pack", label: "资源包",
                                           usedPercent: min(100, max(0, pUsed / cap * 100)),
                                           detail: RateLimitWindow.usedOfTotal(pUsed, cap),
                                           used: pUsed, total: cap))
        }
        return RateLimitSnapshot(providerId: providerId, windows: windows,
                                 planType: plan, capturedAt: now, error: nil)
    }

    /// expiresAt 是 ms epoch；253402214400000（year 9999）等哨兵值当作"无重置"→ nil
    private static func parseExpiresAt(_ v: Any?) -> Date? {
        guard let ms = (v as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        // > year 2100 视作永不过期哨兵
        if ms > 4_102_444_800_000 { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    // MARK: - Qoder IDE vscdb 提取

    /// 只读打开 vscdb，取 ItemTable 某 key 的 value（不碰钥匙串）
    static func readVscdbValue(db path: String, key: String) -> Data? {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key=?", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }; return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))  // SQLITE_TRANSIENT
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr).data(using: .utf8)
    }

    /// `{"type":"Buffer","data":[118,49,48,…]}` → 原始密文字节（含 v10 前缀）
    static func bytesFromNodeBuffer(_ json: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let arr = obj["data"] as? [NSNumber] else { return nil }
        return Data(arr.map { $0.uint8Value })
    }

    /// 在解密出的 userInfo JSON 里递归找 token 型字段（IDE 的 token 字段名未定，宽松匹配）
    static func findToken(in obj: Any) -> String? {
        let keys = ["token", "accessToken", "access_token", "apiToken", "jwt", "idToken", "id_token"]
        if let dict = obj as? [String: Any] {
            for k in keys {
                if let v = dict[k] as? String, !v.isEmpty { return v }
            }
            for v in dict.values {
                if let found = findToken(in: v) { return found }
            }
        } else if let arr = obj as? [Any] {
            for v in arr {
                if let found = findToken(in: v) { return found }
            }
        }
        return nil
    }

    // MARK: - Electron safeStorage 解密

    /// 钥匙串读指定 safeStorage 密码 → PBKDF2-SHA1(salt="saltysalt", 1003, 16) → AES key。
    /// ⚠️ 首次调用弹系统授权框（`QoderWork Safe Storage` / `Qoder Safe Storage` 各弹各的）。
    static func deriveKey(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let pwData = item as? Data else { return nil }

        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBuf -> Int32 in
            pwData.withUnsafeBytes { pwBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBuf.baseAddress, pwData.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBuf.baseAddress, 16)
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// 去 `v10` 前缀 → AES-128-CBC 解密（IV = 16 个空格）→ 去 PKCS7 padding。
    static func decrypt(_ blob: Data, key: Data) -> Data? {
        guard blob.count > 3 else { return nil }
        let enc = blob.dropFirst(3)   // strip "v10"
        let iv = [UInt8](repeating: 0x20, count: 16)
        let outCap = enc.count + kCCBlockSizeAES128
        var out = Data(count: outCap)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            enc.withUnsafeBytes { encBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        0,   // 无 padding option，手动去 PKCS7
                        keyBuf.baseAddress, 16,
                        iv,
                        encBuf.baseAddress, enc.count,
                        outBuf.baseAddress, outCap,
                        &moved)
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        out.removeSubrange(moved..<out.count)
        // 去 PKCS7 padding
        if let pad = out.last, pad >= 1, pad <= 16, out.count >= Int(pad) {
            out.removeLast(Int(pad))
        }
        return out
    }
}
