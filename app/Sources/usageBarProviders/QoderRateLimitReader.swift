import Foundation
import Security
import CommonCrypto
import SQLite3
import usageBarCore

/// Qoder 账号额度读取（v0.3.24）——账号级配额，覆盖 Qoder 全家桶（CLI / Work / IDE 共享一份）。
///
/// **额度值永远走官方 API**（`GET https://openapi.qoder.sh/api/v2/quota/usage`，2026-07-14 探针实证，见 spec §4.3）：
/// ```json
/// {"userType":"personal_standard","usageType":"credits","totalUsagePercentage":37.0,
///  "userQuota":{"total":5000,"used":1850,"remaining":3150,"percentage":37,"unit":"credits"},
///  "expiresAt":<ms>}
/// ```
///
/// 变的只是**从哪拿 token**——按可靠性降级，谁登录了用谁（用户可能只装了其中一个）：
/// 1. **QoderWork**：`…/QoderWork/auth-v2.dat` → 钥匙串 `QoderWork Safe Storage` 解 safeStorage(v10)；
/// 2. **Qoder IDE**：`…/Qoder/User/globalStorage/state.vscdb` 里 `secret://aicoding.auth.userInfo`
///    （值是 `{"type":"Buffer","data":[v10…]}`）→ 钥匙串 `Qoder Safe Storage` 解同款 safeStorage。
///
/// 每档先做**免费的存在性检查**（文件/DB 在不在），命中才碰对应钥匙串 → 最多弹一次；解出的 token 内存缓存跨刷新复用。
/// （Qoder CLI `~/.qoder/.auth/user` 用原生二进制里的固定密钥加密，机器码派生试过均不中、破解需反汇编 → 见调研 §Qoder降级，暂缓。）
public struct QoderRateLimitReader {
    public init() {}

    /// Qoder 全家桶三个 provider 实例共享同一份账号级快照
    public static let providerIds = ["qoder-cli", "qoder-work", "qoder-ide"]
    private static let endpoint = "https://openapi.qoder.sh/api/v2/quota/usage"

    private var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// ⚠️ 解密后 token 内存缓存（跨刷新复用）——不能每次刷新都读钥匙串解密，否则每 10 分钟弹一次授权框。
    nonisolated(unsafe) private static var cachedToken: String?

    /// 取消授权/重置时清缓存 → 下次读重新解密（重新授权）
    public static func clearCache() { cachedToken = nil }

    /// 返回一个「代表账号」的快照（providerId = "qoder-work"）；调度层复制到三个 qoder 实例。
    public func read(now: Date = Date()) async -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: "qoder-work", windows: [], capturedAt: now, error: e)
        }

        // 1. 优先用缓存 token（不碰钥匙串 → 不弹框）
        if let tok = Self.cachedToken {
            let snap = await request(token: tok, now: now)
            if snap.error != .credentialUnavailable { return snap }
            Self.cachedToken = nil   // 401 → 清缓存，下面重新走降级链
        }

        // 2. 降级链拿 token（QoderWork → Qoder IDE），谁登录用谁
        guard let tok = acquireToken() else { return fail(.credentialUnavailable) }
        Self.cachedToken = tok
        return await request(token: tok, now: now)
    }

    // MARK: - token 降级链

    /// 按顺序探测各来源；每档先做免费存在性检查，命中才碰钥匙串。返回第一个拿到的 token。
    private func acquireToken() -> String? {
        tokenFromQoderWork() ?? tokenFromQoderIDE()
    }

    /// A 档 · QoderWork：解 auth-v2.dat / auth.dat（钥匙串 `QoderWork Safe Storage`）
    private func tokenFromQoderWork() -> String? {
        let dir = appSupport.appendingPathComponent("QoderWork")
        let files = ["auth-v2.dat", "auth.dat"].map { dir.appendingPathComponent($0) }
        guard files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let key = Self.deriveKey(service: "QoderWork Safe Storage") else { return nil }
        for url in files {
            guard let enc = try? Data(contentsOf: url),
                  let dec = Self.decrypt(enc, key: key),
                  let obj = try? JSONSerialization.jsonObject(with: dec) as? [String: Any] else { continue }
            if let t = obj["token"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    /// B 档 · Qoder IDE：vscdb `secret://aicoding.auth.userInfo`（钥匙串 `Qoder Safe Storage`）
    private func tokenFromQoderIDE() -> String? {
        let db = appSupport.appendingPathComponent("Qoder/User/globalStorage/state.vscdb").path
        // 免费检查：DB 在不在 + 有没有 userInfo（读明文 vscdb，不碰钥匙串）
        guard FileManager.default.fileExists(atPath: db),
              let bufferJSON = Self.readVscdbValue(db: db, key: "secret://aicoding.auth.userInfo"),
              let enc = Self.bytesFromNodeBuffer(bufferJSON),
              let key = Self.deriveKey(service: "Qoder Safe Storage"),
              let dec = Self.decrypt(enc, key: key),
              let obj = try? JSONSerialization.jsonObject(with: dec) else { return nil }
        return Self.findToken(in: obj)
    }

    private func request(token tok: String, now: Date) async -> RateLimitSnapshot {
        func fail(_ e: RateLimitError) -> RateLimitSnapshot {
            RateLimitSnapshot(providerId: "qoder-work", windows: [], capturedAt: now, error: e)
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
            let plan = obj["userType"] as? String   // API 响应自带 userType，无需本地兜底
            let quota = obj["userQuota"] as? [String: Any]
            let total = (quota?["total"] as? NSNumber)?.doubleValue ?? 0
            if total <= 0 {
                // 免费版（Community）无信用点额度概念
                return fail(.noQuotaData)
            }
            let used = (quota?["used"] as? NSNumber)?.doubleValue ?? 0
            let pct = (quota?["percentage"] as? NSNumber)?.doubleValue
                ?? (obj["totalUsagePercentage"] as? NSNumber)?.doubleValue ?? 0
            let unit = (quota?["unit"] as? String) ?? "credits"
            let resets = Self.parseExpiresAt(obj["expiresAt"])
            let detail = String(format: "%.0f / %.0f %@", used, total, unit)
            let win = RateLimitWindow(kind: "monthly", label: "月", usedPercent: pct,
                                      resetsAt: resets, detail: detail)
            return RateLimitSnapshot(providerId: "qoder-work", windows: [win],
                                     planType: plan, capturedAt: now, error: nil)
        } catch {
            return fail(.network)
        }
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
