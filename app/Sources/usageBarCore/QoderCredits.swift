import Foundation

/// 只保留积分观测与归属，不保存用户正文或鉴权数据。金额保持小数，显示时才舍入。
public struct QoderCreditObservation: Codable, Sendable, Equatable {
    public var recordKey: String
    public var requestKey: String
    public var identityKind: String
    public var timestamp: Date
    public var sessionId: String
    public var model: String
    public var credits: Decimal?
    public var originalCredits: Decimal?
    public var billable: Bool?
    public var subagentId: String?
    public var isSidechain: Bool?
    public var attributionConflict: Bool
    public var invalidFields: [String]

    public init(recordKey: String, requestKey: String, identityKind: String, timestamp: Date,
                sessionId: String, model: String, credits: Decimal?, originalCredits: Decimal?,
                billable: Bool?, subagentId: String?, isSidechain: Bool?,
                attributionConflict: Bool, invalidFields: [String]) {
        self.recordKey = recordKey; self.requestKey = requestKey; self.identityKind = identityKind
        self.timestamp = timestamp; self.sessionId = sessionId; self.model = model
        self.credits = credits; self.originalCredits = originalCredits; self.billable = billable
        self.subagentId = subagentId; self.isSidechain = isSidechain
        self.attributionConflict = attributionConflict; self.invalidFields = invalidFields
    }
}

/// 按文件增量读取，历史观测追加保留；聚合时跨全部持久记录按 requestKey 去重。
public struct QoderCreditFile: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var sourcePath: String
    public var observations: [QoderCreditObservation] = []
    public var titles: [String: String] = [:]
    public var modelNames: [String: String] = [:]
    public var unreadable = false
    public var malformedRecords = 0
    public var sourceMissing = false

    public init(sourcePath: String) { self.sourcePath = sourcePath }
}

/// 独立于 token 数量的积分覆盖状态。0 积分、有部分记录、完全未知是三种不同状态。
public struct CreditUsage: Sendable, Equatable {
    public var amount: Decimal = 0
    public var recordedRequests = 0
    public var missingRequests = 0
    public var conflictRequests = 0
    public var nonBillableRequests = 0
    public var billingUnknownRequests = 0
    public var weakIdentityRequests = 0
    public var subagentRequests = 0
    public var uncoveredHistory = false
    public var sourceIssues = false

    public init() {}
    public var hasValue: Bool { recordedRequests > 0 }
    public var isPartial: Bool { missingRequests > 0 || conflictRequests > 0 || uncoveredHistory || sourceIssues }
    public var hasActivity: Bool { hasValue || missingRequests > 0 || conflictRequests > 0 || sourceIssues }
    public var value: Double { NSDecimalNumber(decimal: amount).doubleValue }

    public mutating func add(_ other: CreditUsage) {
        amount += other.amount; recordedRequests += other.recordedRequests
        missingRequests += other.missingRequests; conflictRequests += other.conflictRequests
        nonBillableRequests += other.nonBillableRequests; billingUnknownRequests += other.billingUnknownRequests
        weakIdentityRequests += other.weakIdentityRequests; subagentRequests += other.subagentRequests
        uncoveredHistory = uncoveredHistory || other.uncoveredHistory
        sourceIssues = sourceIssues || other.sourceIssues
    }

    public var label: String {
        guard hasValue else { return "积分未知" }
        let number: String
        if value > 0 && value < 0.0001 { number = "<0.0001" }
        else { number = String(format: value < 1 && value > 0 ? "%.4f" : "%.2f", value) }
        return "\(number) 积分" + (isPartial ? "*" : "")
    }

    public var explanation: String {
        var parts = ["本地记录积分，未与官方最终账单对账"]
        if isPartial { parts.append("仅统计有积分记录且无冲突的请求，缺失部分不按 0 计算") }
        if conflictRequests > 0 { parts.append("\(conflictRequests) 个请求的积分或归属冲突，未计入合计") }
        if sourceIssues { parts.append("部分文件未能完整读取") }
        if weakIdentityRequests > 0 { parts.append("\(weakIdentityRequests) 个请求缺少请求编号，按消息或记录编号识别，跨副本去重可靠性有限") }
        if nonBillableRequests > 0 || billingUnknownRequests > 0 {
            parts.append("含未计费或计费状态未知的记录，保留日志积分原值，不代表实际扣款")
        }
        return parts.joined(separator: "；")
    }
}
