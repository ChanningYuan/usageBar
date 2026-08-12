import Foundation

/// 账号额度快照的持久化存储（v0.3.24）。
///
/// 全部 provider 的最新快照合成一个 dict，JSON 存到 Application Support/usageBar/rate-limit-snapshot.json。
/// 读写抽象在此类后面——将来做小组件时把 `diskPath` 换成 App Group 共享容器，**调用方零改动**。
///
/// 与 `FileMtimeCache`（按日 token 聚合缓存）无关、不复用——语义不搭（那是增量缓存，这是当前状态快照）。
@MainActor
public final class RateLimitStore: ObservableObject {
    public static let shared = RateLimitStore()

    /// providerId → 最新快照
    @Published public private(set) var snapshots: [String: RateLimitSnapshot] = [:]

    private var loadedFromDisk = false

    private init() {}

    /// 磁盘路径（与 FileMtimeCache 同目录）
    public static var diskPath: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("usageBar", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("rate-limit-snapshot.json")
    }

    /// 启动时从磁盘读一次（幂等）
    public func loadFromDisk() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: Self.diskPath) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let dict = try? dec.decode([String: RateLimitSnapshot].self, from: data) {
            snapshots = dict
        }
    }

    /// 写入/更新某 provider 的快照，并落盘。
    ///
    /// ⚠️ 采集失败（网络/429/超时）时**保留上次成功的快照**、只更新 error——不要用空快照覆盖，
    /// 否则一次网络抖动就把有效数据抹掉。调用方传 error 快照，这里做「保留 windows」的合并。
    public func put(_ snap: RateLimitSnapshot) {
        if snap.error == .network, let prev = snapshots[snap.providerId], !prev.windows.isEmpty {
            // 网络类失败：保留上次的 windows 与全部附加字段（陈旧展示），只记录这次没刷成
            let merged = RateLimitSnapshot(
                providerId: snap.providerId,
                windows: prev.windows,
                planType: prev.planType,
                capturedAt: prev.capturedAt,   // 保留上次成功时间 → UI 据此算「陈旧」
                error: .network,
                credits: prev.credits, spendCap: prev.spendCap,
                spendControlReached: prev.spendControlReached,
                rateLimitReachedType: prev.rateLimitReachedType,
                resetCoupons: prev.resetCoupons)
            snapshots[snap.providerId] = merged
        } else {
            snapshots[snap.providerId] = snap
        }
        persist()
    }

    /// 移除某 provider 的快照（关闭监测开关时用）
    public func remove(_ providerId: String) {
        guard snapshots[providerId] != nil else { return }
        snapshots.removeValue(forKey: providerId)
        persist()
    }

    public func snapshot(for providerId: String) -> RateLimitSnapshot? {
        snapshots[providerId]
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(snapshots) else { return }
        try? data.write(to: Self.diskPath, options: .atomic)
    }
}
