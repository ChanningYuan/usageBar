import CryptoKit
import Foundation
import usageBarCore

/// 本机豆包工作的位置。
public enum DoubaoWorkEnv {
    /// `~/Library/Application Support/DoubaoWork`（官网直装、无沙盒，cookie 库与 `Local State` 都在这）
    public static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DoubaoWork", isDirectory: true)
    }

    /// 已安装的 DoubaoWork.app（/Applications 或 ~/Applications），没装返回 nil。
    public static var appURL: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/DoubaoWork.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DoubaoWork.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 「这台机器有豆包工作」：装了 app，或留有它的数据目录（卸载后仍有历史可看）。
    /// 设置页数据源行 / 首次运行保留判据 / 主列表「去开启」提示都看它。
    public static func isInstalled() -> Bool {
        appURL != nil || FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("Default/Cookies").path)
    }
}

/// 豆包工作 provider（v0.3.45）。
///
/// ## 只有积分，没有 token
///
/// 豆包工作不向客户端提供 token 消耗数（2026-09-24 实抓回复流定案，见 `DoubaoWorkAPI` 顶部说明），
/// 唯一的计量是服务端「额度消耗明细」里逐笔的积分。所以账本里每一笔：
/// - `records` 的 token = 0 → 主列表数字位显示「—」、进度条空（与其它无数据行同一口径）；
/// - `details` 的 `nativeCost` = 这笔的积分，会话 = 消耗场景（会话标题）、模型 = 模型展示名
///   → 详情页 Hero 副行 / 按模型 / 按会话都显示真实积分。
///
/// ## 数据从哪来
///
/// 本 provider **不联网**：联网在 `DoubaoWorkStore.refresh()`（额度监测开关打开后，随每次刷新由
/// `RateLimitCoordinator` 触发，要读钥匙串）。这里只把本地镜像（`doubao-work.json`）逐笔写进账本——
/// 每笔一条、按消息编号做 key：同一笔的值涨了就覆盖，不会重复计；服务端 30 天后删掉的笔，镜像和账本里都还在。
/// 账本整份作废重建时，也是从镜像恢复（服务端那头早没了）。
public struct DoubaoWorkProvider: UsageProvider {
    public let id = "doubao-work"
    public let displayName = "豆包工作"
    public let iconSymbol = "sparkles"
    public let brandColor = "#3C7BFF"

    private let store: DoubaoWorkStore
    private let ledger: FileMtimeCache

    public init(store: DoubaoWorkStore = .shared, ledger: FileMtimeCache = .shared) {
        self.store = store
        self.ledger = ledger
    }

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let items = await store.allItems()
        // 主列表与详情页都读账本（CLAUDE.md 不变量①）：每笔的主列表记录与明细存进**同一条**账本记录
        for item in items {
            await ledger.store(Self.ledgerEntry(for: item))
        }
        return Self.dailyRecords(from: items)
    }

    /// 账本 key 前缀（一笔一条）。主列表按它挑出豆包工作的积分日期。
    public static let ledgerPrefix = "usagebar://doubao-work/item/"

    static func ledgerEntry(for item: DoubaoWorkUsageItem) -> FileCacheEntry {
        let date = DailyAggregator.dateString(for: item.occurredAt)
        return FileCacheEntry(
            filePath: ledgerPrefix + item.itemId,
            mtime: item.occurredAt,
            // 合成条目的「内容量」：积分×100（取整）。值涨了它跟着变，但合成条目不走 mtime 校验，只作记录
            size: Int((item.credits * 100).rounded()),
            records: [FileDailyRecord(provider: "doubao-work", date: date, token: 0)],
            details: [FileDetailRecord(
                provider: "doubao-work",
                date: date,
                sessionId: sessionId(forTitle: item.title),
                title: item.title,
                model: item.model,
                lastActivity: item.occurredAt,
                tokens: TokenBreakdown(),
                nativeCost: item.credits)])
    }

    /// 明细里**没有会话 id**，只有会话标题，所以按标题分组：同一会话里的多轮消耗归到一行。
    /// 已知局限：两个同名的不同会话会合成一行（积分合计仍是对的，只是分不开）。
    /// 用标题的哈希做 id，别让标题原文当 key（详情页副标题另行生成，不看它）。
    static func sessionId(forTitle title: String) -> String {
        "t-" + SHA256.hash(data: Data(title.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func dailyRecords(from items: [DoubaoWorkUsageItem]) -> [FileDailyRecord] {
        Set(items.map { DailyAggregator.dateString(for: $0.occurredAt) }).sorted().map {
            FileDailyRecord(provider: "doubao-work", date: $0, token: 0)
        }
    }
}

/// 豆包工作详情页的收尾加工（v0.3.45）。聚合本身走通用的 `LedgerDetailAggregator`，这里只补两件它不知道的事。
public enum DoubaoWorkDetail {
    /// - 会话行副标题：「09-13 · Auto」——最后一次消耗的日期 + 这个会话用过的模型（积分多的在前）。
    ///   通用聚合器拿会话 id 前 8 位当副标题；豆包的会话 id 是标题哈希，给人看没意义。
    /// - 积分同步状态：`costAvailable` / `costSyncedAt`，Hero 据此写「截至 HH:mm」或「积分未开启」。
    public static func decorated(
        _ detail: ProviderDetail, details: [FileDetailRecord],
        window: TimeWindow, weekStartMonday: Bool, now: Date = Date(),
        costAvailable: Bool, costSyncedAt: Date?
    ) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)
        var modelsBySession: [String: [String: Double]] = [:]
        for d in details where d.provider == "doubao-work" && inWindow(d.date) {
            modelsBySession[d.sessionId, default: [:]][d.model, default: 0] += d.nativeCost ?? 0
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "zh_CN")
        day.dateFormat = "MM-dd"
        let sessions = detail.sessions.map { s -> SessionDetailRecord in
            let models = (modelsBySession[s.sessionId] ?? [:])
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map(\.key)
            let parts = [day.string(from: s.lastActivity), models.joined(separator: " / ")].filter { !$0.isEmpty }
            return SessionDetailRecord(sessionId: s.sessionId, title: s.title,
                                       subtitle: parts.joined(separator: " · "),
                                       lastActivity: s.lastActivity, tokens: s.tokens, cost: s.cost,
                                       credits: s.credits, models: s.models)
        }
        return ProviderDetail(providerId: detail.providerId, windowId: detail.windowId,
                              tokens: detail.tokens, cost: detail.cost,
                              costAvailable: costAvailable, costSyncedAt: costSyncedAt,
                              sources: detail.sources, models: detail.models, sessions: sessions,
                              credits: detail.credits)
    }
}
