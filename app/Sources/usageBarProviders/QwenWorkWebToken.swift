import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Security
import usageBarCore

// MARK: - 千问办公「网页令牌」（v0.3.38）
//
// 背景（docs/0910-千问办公积分链路修复/千问办公积分修复-spec.md §2）：
// 2026-08-20 起千问办公桌面 app 自动续出的登录令牌是 `aud=oauth_app` 一种，qwenwork.cn 的账单流水接口
// `/user/billings` 只认网页登录那种（`aud=user`，48 小时一换）。于是「今日已用 / 按会话积分」这条线
// 必须另外拿一张网页令牌；来源优先级 = usageBar 自己的钥匙串缓存 → Chrome cookie 自动导入 → 用户手动粘贴。
// 这套「读浏览器 cookie + 手动粘贴」是同类开源项目（CodexBar 对 Qoder / 阿里云 Token Plan / Qwen Cloud）的现成模式（spec §7）。

/// JWT 只做**只读解析**（不验签）：我们只需要 `exp` 判过期、`aud` 判种类。
public enum QwenWorkJWT {
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    public static func expiry(_ token: String) -> Date? {
        guard let exp = claims(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    public static func audience(_ token: String) -> String? {
        claims(token)?["aud"] as? String
    }

    /// 剩余有效期不足 60 秒视为不可用（照 CodexBar 的 Cursor 规则）。
    public static func isUsable(_ token: String, now: Date = Date()) -> Bool {
        guard let exp = expiry(token) else { return false }
        return exp.timeIntervalSince(now) > 60
    }
}

/// 手动粘贴：接受整段 cURL、`Cookie:` 头、`token=…` 片段或裸 JWT，只抽出网页令牌那一段。
public enum QwenWorkWebTokenExtractor {
    public static func extract(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 1) cookie 里的 token=eyJ…（cURL 的 -b '…' 或 Cookie: 头都长这样）
        if let range = trimmed.range(of: #"(?:^|[;\s'"])token=([A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)"#,
                                     options: .regularExpression) {
            let hit = String(trimmed[range])
            if let eq = hit.range(of: "token=") { return String(hit[eq.upperBound...]) }
        }
        // 2) 裸 JWT（三段 base64url）
        if trimmed.range(of: #"^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil {
            return trimmed
        }
        // 3) 文本里任意位置的 JWT（比如从 Authorization: Bearer … 抠出来的）
        if let range = trimmed.range(of: #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return nil
    }
}

/// usageBar 自己的钥匙串条目：缓存一张有效的网页令牌，之后每 5 分钟先读这里，不再反复碰 Chrome 的库。
/// 条目由 usageBar 自己创建，同一签名的 app 读自己的条目不弹授权框。
public struct QwenWorkWebTokenRecord: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case chrome, manual }
    public let token: String
    public let source: Source
    public let savedAt: Date

    public init(token: String, source: Source, savedAt: Date = Date()) {
        self.token = token
        self.source = source
        self.savedAt = savedAt
    }

    public var expiresAt: Date? { QwenWorkJWT.expiry(token) }
}

public enum QwenWorkWebTokenKeychain {
    static let service = "com.yuanchenyu.usageBar"
    static let account = "qwenwork-web-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func load() -> QwenWorkWebTokenRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QwenWorkWebTokenRecord.self, from: data)
    }

    @discardableResult
    public static func save(_ record: QwenWorkWebTokenRecord) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Chrome 「Safe Storage」授权被拒后的退避（6 小时内不再自动碰钥匙串，免得反复弹框；照 CodexBar 的规则）。
public enum QwenWorkChromeBackoff {
    static let key = "usagebar.qwenWorkChromeDeniedUntil.v1"
    public static let duration: TimeInterval = 6 * 3600

    public static func deniedUntil(now: Date = Date()) -> Date? {
        guard let until = UserDefaults.standard.object(forKey: key) as? Date, until > now else { return nil }
        return until
    }

    public static func noteDenied(now: Date = Date()) {
        UserDefaults.standard.set(now.addingTimeInterval(duration), forKey: key)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 从 Chrome 的 cookie 库里读 qwenwork.cn 的 `token`。
///
/// - 库文件在 Chrome 运行时被锁着，**先拷到临时目录再只读打开**。
/// - 值是 `v10` + AES-128-CBC，密钥 = PBKDF2-SHA1(「Chrome Safe Storage」钥匙串密码, "saltysalt", 1003, 16)，
///   IV 16 个空格——与 Electron safeStorage 同款，直接复用 `QoderRateLimitReader.deriveKey/decrypt`。
/// - ⚠️ Chrome 130（2024-10）起明文前面会多 32 字节的 SHA256(host_key)，解出来先剥掉再当 JWT 用。
public enum ChromeCookieReader {
    public enum Outcome: Sendable, Equatable {
        /// 找到并解出一张令牌（不保证未过期，调用方再看 exp）
        case token(String)
        /// Chrome 装了、也能读，但没有 qwenwork.cn 的 token（用户没在 Chrome 登录过网页版）
        case notFound
        /// 钥匙串授权被拒 / 不可交互
        case denied
        /// 本机没有 Chrome 的 cookie 库（没装或换了浏览器）
        case noBrowser
    }

    public static let safeStorageService = "Chrome Safe Storage"

    /// Chrome 各 Profile 的 Cookies 库路径（Default / Profile 1 / …）。
    public static func cookieDatabases(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { dir in
            let db = dir.appendingPathComponent("Cookies")
            return FileManager.default.fileExists(atPath: db.path) ? db : nil
        }.sorted { $0.path < $1.path }
    }

    public static func qwenWorkToken(now: Date = Date()) -> Outcome {
        let databases = cookieDatabases()
        guard !databases.isEmpty else { return .noBrowser }
        var status: OSStatus = errSecSuccess
        guard let key = QoderRateLimitReader.deriveKey(service: safeStorageService, status: &status) else {
            // 没有这个钥匙串条目 = Chrome 从没写过 Safe Storage（几乎等于没装 Chrome）
            return status == errSecItemNotFound ? .noBrowser : .denied
        }
        var best: (token: String, exp: Date)?
        for db in databases {
            for blob in encryptedTokens(in: db) {
                guard let token = decryptCookieValue(blob, key: key),
                      let exp = QwenWorkJWT.expiry(token) else { continue }
                if best == nil || exp > best!.exp { best = (token, exp) }
            }
        }
        guard let best else { return .notFound }
        return .token(best.token)
    }

    /// 解密 cookie 值：`v10` 前缀 → AES → 剥 32 字节 host 哈希前缀（Chrome ≥130）→ UTF-8。
    static func decryptCookieValue(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3, String(data: blob.prefix(3), encoding: .ascii) == "v10",
              let plain = QoderRateLimitReader.decrypt(blob, key: key) else { return nil }
        if let s = String(data: plain, encoding: .utf8), s.hasPrefix("eyJ") { return s }
        if plain.count > 32, let s = String(data: plain.dropFirst(32), encoding: .utf8), s.hasPrefix("eyJ") { return s }
        return nil
    }

    /// 拷贝到临时目录后只读查询 `cookies` 表，返回所有 qwenwork.cn 下名为 token 的密文。
    static func encryptedTokens(in database: URL) -> [Data] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagebar-chrome-cookies-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("Cookies")
        guard (try? FileManager.default.copyItem(at: database, to: copy)) != nil else { return [] }
        for suffix in ["-journal", "-wal"] {
            let side = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        let uri = "file:\(copy.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT encrypted_value FROM cookies WHERE host_key LIKE '%qwenwork.cn' AND name = 'token' ORDER BY expires_utc DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [Data] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(stmt, 0) {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                out.append(Data(bytes: bytes, count: count))
            }
        }
        return out
    }
}
