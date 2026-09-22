import Foundation
import usageBarCore

/// 从同一账本快照生成总量、模型、会话及会话内模型积分。不得读取源日志。
public enum QoderCreditsAggregator {
    private struct Group: Hashable {
        let session: String
        let model: String
        let date: String
    }
    private struct Row {
        var tokens = TokenBreakdown()
        var credits = CreditUsage()
        var activity = Date.distantPast
    }

    public static func aggregate(entries: [FileCacheEntry], window: TimeWindow,
                                 weekStartMonday: Bool = true, now: Date = Date()) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)
        let files = entries.sorted {
            $0.mtime != $1.mtime ? $0.mtime < $1.mtime : $0.filePath < $1.filePath
        }.compactMap(\.qoderCredits)
        var titles: [String: String] = [:]
        var names: [String: String] = [:]
        var titleDates: [String: Date] = [:]
        for file in files {
            titles.merge(file.titles) { _, new in new }
            names.merge(file.modelNames) { _, new in new }
        }
        var rows: [Group: Row] = [:]
        let requests = Dictionary(grouping: files.flatMap(\.observations), by: \.requestKey)
        let coveredPaths = Set(files.map { URL(fileURLWithPath: $0.sourcePath).resolvingSymlinksInPath().path })
        for entry in entries {
            for d in entry.details where d.provider == "qoder-cli" && inWindow(d.date) {
                let key = Group(session: d.sessionId, model: d.model, date: d.date)
                rows[key, default: Row()].tokens.add(d.tokens)
                rows[key, default: Row()].activity = max(rows[key]?.activity ?? .distantPast, d.lastActivity)
                if entry.filePath.contains("/.usagebar-request-ledger/") {
                    let request = "request:" + URL(fileURLWithPath: entry.filePath).lastPathComponent
                    if requests[request] == nil { rows[key, default: Row()].credits.uncoveredHistory = true }
                } else if !coveredPaths.contains(URL(fileURLWithPath: entry.filePath).resolvingSymlinksInPath().path) {
                    // 同模型同一天的新记录，不能替另一份已丢源文件的旧用量证明积分完整。
                    rows[key, default: Row()].credits.uncoveredHistory = true
                }
                if !d.title.isEmpty, d.lastActivity >= (titleDates[d.sessionId] ?? .distantPast) {
                    titleDates[d.sessionId] = d.lastActivity
                    if !files.contains(where: { $0.titles[d.sessionId] != nil }) { titles[d.sessionId] = d.title }
                }
            }
        }
        var observed = Set<Group>()
        for request in requests.keys.sorted() {
            let copies = requests[request]!
            guard copies.contains(where: { inWindow(DailyAggregator.dateString(for: $0.timestamp)) }) else { continue }
            let dates = Set(copies.map { DailyAggregator.dateString(for: $0.timestamp) })
            let sessions = Set(copies.map(\.sessionId)), models = Set(copies.map(\.model))
            let values = Set(copies.compactMap(\.credits))
            let originals = Set(copies.compactMap(\.originalCredits))
            let billing = Set(copies.compactMap(\.billable))
            let attributionConflict = sessions.count != 1 || models.count != 1 || dates.count != 1
                || copies.contains(where: \.attributionConflict)
            let conflict = attributionConflict || values.count > 1 || originals.count > 1 || billing.count > 1
            // 冲突记录没有可信归属；单列待确认，不凭文件顺序塞进某个真实会话。
            let session = attributionConflict ? "usagebar:unresolved-credits" : sessions.first!
            let model = attributionConflict ? "(归属待确认)" : models.first!
            let date = dates.filter(inWindow).sorted().first!
            let key = Group(session: session, model: model, date: date)
            observed.insert(key)
            var usage = CreditUsage()
            if conflict { usage.conflictRequests = 1 }
            else if let amount = values.first { usage.amount = amount; usage.recordedRequests = 1 }
            else { usage.missingRequests = 1 }
            if billing.first == false { usage.nonBillableRequests = 1 }
            if billing.isEmpty { usage.billingUnknownRequests = 1 }
            if copies.contains(where: { $0.identityKind != "request" }) { usage.weakIdentityRequests = 1 }
            if copies.contains(where: { $0.subagentId != nil || $0.isSidechain == true }) { usage.subagentRequests = 1 }
            rows[key, default: Row()].credits.add(usage)
            rows[key, default: Row()].activity = max(rows[key]?.activity ?? .distantPast, copies.map(\.timestamp).max()!)
        }
        var hero = Row()
        var models: [String: Row] = [:]
        var sessions: [String: Row] = [:]
        var sessionModels: [String: [String: Row]] = [:]
        func merged(_ a: Row?, _ b: Row) -> Row {
            var result = a ?? Row()
            result.tokens.add(b.tokens); result.credits.add(b.credits)
            result.activity = max(result.activity, b.activity)
            return result
        }
        for key in rows.keys.sorted(by: { ($0.date, $0.session, $0.model) < ($1.date, $1.session, $1.model) }) {
            var row = rows[key]!
            if row.tokens.total > 0 && !observed.contains(key) { row.credits.uncoveredHistory = true }
            hero = merged(hero, row)
            models[key.model] = merged(models[key.model], row)
            sessions[key.session] = merged(sessions[key.session], row)
            sessionModels[key.session, default: [:]][key.model] = merged(sessionModels[key.session]?[key.model], row)
        }
        hero.credits.sourceIssues = files.contains { $0.unreadable || $0.malformedRecords > 0 }
        func modelRecords(_ values: [String: Row]) -> [ModelDetailRecord] {
            values.map { id, row in
                ModelDetailRecord(modelId: id, tokens: row.tokens, cost: row.credits.value,
                                  credits: row.credits, displayName: names[id])
            }.sorted {
                if $0.tokens.total != $1.tokens.total { return $0.tokens.total > $1.tokens.total }
                return $0.modelId < $1.modelId
            }
        }
        let sessionRecords = sessions.map { id, row in
            SessionDetailRecord(sessionId: id,
                                title: id == "usagebar:unresolved-credits" ? "归属待确认的请求" : titles[id] ?? "(无标题会话)",
                                subtitle: id == "usagebar:unresolved-credits" ? "请核对原始记录" : String(id.prefix(8)),
                                lastActivity: row.activity, tokens: row.tokens, cost: row.credits.value,
                                credits: row.credits, models: modelRecords(sessionModels[id] ?? [:]))
        }.sorted {
            if $0.tokens.total != $1.tokens.total { return $0.tokens.total > $1.tokens.total }
            return $0.sessionId < $1.sessionId
        }
        return ProviderDetail(providerId: "qoder-cli", windowId: window.id, tokens: hero.tokens,
                              cost: hero.credits.value, costAvailable: hero.credits.hasValue,
                              models: modelRecords(models), sessions: sessionRecords, credits: hero.credits)
    }
}
