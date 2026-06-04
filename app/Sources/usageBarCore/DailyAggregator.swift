import Foundation

/// 把 5 个 provider 的所有 FileDailyRecord 平铺聚合 → 20 条 StatRecord 的 helper
public enum DailyAggregator {

    /// 本机当前时区的 yyyy-MM-dd 格式化器。
    /// 用 `TimeZone.current` 而非硬编码 Asia/Shanghai —— 「今日」按用户本地午夜切,
    /// 跨时区同事(非 +08)也能正确归日。数据里的时间戳已是绝对时刻(带 tz 或 unix ms),
    /// 转本地日界即可。
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// 把 ts 转成本地时区的 "yyyy-MM-dd"
    public static func dateString(for date: Date) -> String {
        dayFmt.string(from: date)
    }

    /// 当前本地日期字符串
    public static var todayString: String {
        dayFmt.string(from: Date())
    }

    /// 计算 N 天前的日期字符串（含今天就是 0）
    public static func dayStringDaysAgo(_ days: Int, from now: Date = Date()) -> String {
        dayFmt.string(from: now.addingTimeInterval(TimeInterval(-days) * 86400))
    }

    /// 把所有 daily records 按 (provider, time) 聚合成 20 条 StatRecord
    ///
    /// - Parameters:
    ///   - allDailyRecords: 5 个 provider 平铺的所有 [FileDailyRecord]
    ///   - providerIds: 要包含的 provider id 列表（即使没数据也产出 0 token 记录，保证 UI 5 行不漏）
    ///   - now: 计算窗口的当前时间（测试可注入）
    public static func aggregate(
        allDailyRecords: [FileDailyRecord],
        providerIds: [String],
        now: Date = Date()
    ) -> [StatRecord] {
        let today = dayFmt.string(from: now)
        let day7 = dayStringDaysAgo(6, from: now)   // 含今天 = 最近 7 天（6 天前到今天）
        let day30 = dayStringDaysAgo(29, from: now) // 含今天 = 最近 30 天

        // 按 (provider, date) 求和
        var sumByProviderDate: [String: [String: Int]] = [:]
        for r in allDailyRecords {
            sumByProviderDate[r.provider, default: [:]][r.date, default: 0] += r.token
        }

        var out: [StatRecord] = []
        for pid in providerIds {
            let dailyMap = sumByProviderDate[pid] ?? [:]
            var todayTotal = 0
            var last7Total = 0
            var last30Total = 0
            var allTotal = 0
            for (date, token) in dailyMap {
                allTotal += token
                if date == today {
                    todayTotal += token
                }
                if date >= day7 {
                    last7Total += token
                }
                if date >= day30 {
                    last30Total += token
                }
            }
            out.append(StatRecord(provider: pid, time: "today", token: todayTotal))
            out.append(StatRecord(provider: pid, time: "last7Days", token: last7Total))
            out.append(StatRecord(provider: pid, time: "last30Days", token: last30Total))
            out.append(StatRecord(provider: pid, time: "all", token: allTotal))
        }
        return out
    }
}

// MARK: - 文件 mtime/size 读取 helper

public enum FileMetadata {
    /// 取文件的 (mtime, size)。文件不存在返回 nil
    public static func read(at path: String) -> (mtime: Date, size: Int)? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        guard let mtime = attr[.modificationDate] as? Date else { return nil }
        guard let size = attr[.size] as? Int else { return nil }
        return (mtime, size)
    }
}
