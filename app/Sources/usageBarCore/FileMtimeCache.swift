import Foundation

/// 全局 mtime 增量缓存。
///
/// - 内存：所有 Provider 共享一份 `[String: FileCacheEntry]` 索引（key = filePath）
/// - 持久化：进程退出 / 手动 save 时写到磁盘 JSON
///
/// 用法：
/// ```swift
/// let entry = await FileMtimeCache.shared.lookup(filePath: url.path, mtime: mtime, size: size)
/// if let entry { /* 缓存命中，用 entry.records */ }
/// else { /* 重新解析文件后调 store(...) */ }
/// ```
public actor FileMtimeCache {
    public static let shared = FileMtimeCache()

    private var entries: [String: FileCacheEntry] = [:]
    private var loadedFromDisk = false

    public init() {}

    /// 查缓存。mtime 和 size 都对得上才返回，否则返回 nil（让调用方重新解析）。
    /// 容差 1 秒（文件系统 mtime + JSON ISO 8601 序列化可能丢亚秒精度）。
    /// size 必须完全相等（文件内容有变化时 size 一般也变）。
    public func lookup(filePath: String, mtime: Date, size: Int) -> FileCacheEntry? {
        guard let entry = entries[filePath] else { return nil }
        guard abs(entry.mtime.timeIntervalSinceReferenceDate - mtime.timeIntervalSinceReferenceDate) < 1.0 else {
            return nil
        }
        guard entry.size == size else { return nil }
        return entry
    }

    /// 缓存未命中时，调用方解析完文件后塞回来
    public func store(_ entry: FileCacheEntry) {
        entries[entry.filePath] = entry
    }

    /// 取所有缓存条目（聚合 StatRecord 时用）
    public func allEntries() -> [FileCacheEntry] {
        Array(entries.values)
    }

    /// 清理已经从磁盘消失的文件缓存（避免无限增长）
    ///
    /// ⚠️ 注意:当前聚合走各 provider 的 findFiles(只看现存文件),缓存仅作「按 path 的解析提速」,
    /// 并非历史账本。是否清理孤儿条目取决于「缓存是否要当持久账本」这个尚未拍板的设计决策
    /// (见 README「持久账本」TODO)。在拍板前不接入此方法,保持现状(零调用)。
    public func purgeStale(existingPaths: Set<String>) {
        entries = entries.filter { existingPaths.contains($0.key) }
    }

    public func count() -> Int {
        entries.count
    }

    // MARK: - 持久化

    /// 磁盘 cache 文件路径
    public static var diskPath: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("usageBar", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("file-cache.json")
    }

    /// 启动时从磁盘读 cache（只能调一次，第二次起跳过）
    public func loadFromDisk() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true

        let url = Self.diskPath
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(PersistedCache.self, from: data)
            guard persisted.schemaVersion == PersistedCache.currentSchemaVersion else {
                // schema 不兼容，丢弃旧 cache
                return
            }
            for entry in persisted.entries {
                entries[entry.filePath] = entry
            }
        } catch {
            // cache 损坏，忽略
        }
    }

    /// 退出时把内存 cache 写到磁盘
    public func saveToDisk() {
        let snapshot = PersistedCache(entries: Array(entries.values))
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: Self.diskPath, options: .atomic)
        } catch {
            // 写失败也忍了，下次启动重新算一遍而已
        }
    }
}
