import Foundation

/// Claude Code transcript 中单条消息的模型来源。
///
/// 来源只用于详情页解释流量构成，不参与 provider 主聚合或计价。
public enum ClaudeSource: String, CaseIterable, Sendable, Hashable {
    case official
    case relay

    /// 根据模型域和 `message.id` 判定来源。模型域优先，避免中转伪造 `msg_` 前缀。
    public static func classify(messageId: String, modelId: String) -> ClaudeSource {
        guard modelId.lowercased().hasPrefix("claude-") else { return .relay }
        if messageId.hasPrefix("msg_vrtx_") || messageId.hasPrefix("msg_bdrk_") {
            return .relay
        }
        return messageId.hasPrefix("msg_") ? .official : .relay
    }
}
