import Foundation
import usageBarProviders
import usageBarCore

/// 账号额度采集调度（v0.3.24）。
///
/// **跟随现有 token 刷新**（自动 10 分钟 + ⌘R），不新增节拍器——`UsageViewModel.refresh()` 末尾
/// detached 调 `refreshEnabled()`，与 token 聚合并发、互不阻塞（额度是网络/钥匙串 IO，token 是扫盘）。
///
/// 只跑「已开启」的 provider（`RateLimitSettings`）。Qoder 一次 read → 复制到三个实例快照；
/// 千问办公同轮刷新积分账单缓存（不是额度快照）。
@MainActor
enum RateLimitCoordinator {

    /// 是否允许本次采集去碰系统钥匙串。**冷启动为 false → 不弹授权框**；
    /// 用户「打开弹层 / 手动刷新 / 在设置里开启」这类主动动作才置 true（见各调用点）。
    /// 这样授权只发生在用户真正去看额度时，而不是 app 一启动就弹一堆框。
    static var allowsKeychainAccess = false

    /// 并发去重：一次采集在跑时，后来的调用直接跳过（避免同一轮启动读两遍钥匙串 = 弹两次）。
    private static var inFlight = false

    /// 某逻辑开关当前的数据源是否需要读系统钥匙串（决定冷启动要不要跳过它）。
    /// - Qoder：恒需要（token 全加密）。
    /// - Claude：仅 OAuth 源需要；statusline / CLI 零钥匙串。
    /// - 其余（Codex 走官方 CLI RPC、凭据由 CLI 自管 / Cursor·WorkBuddy 明文）都不需要。
    static func needsKeychain(_ logicalId: String) -> Bool {
        switch logicalId {
        case "qoder", "qwen-work": return true
        case "claude-code": return RateLimitSettings.shared.dataSource(for: "claude-code") == "oauth"
        default: return false
        }
    }

    /// 采集所有已开启的 provider，写入 `RateLimitStore`。
    /// `force` = 用户主动动作，强制允许碰钥匙串（等价于把 `allowsKeychainAccess` 提前置 true）。
    static func refreshEnabled(now: Date = Date(), force: Bool = false) async {
        if force { allowsKeychainAccess = true }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let s = RateLimitSettings.shared
        // 冷启动（allowsKeychainAccess=false）时，跳过需要钥匙串的 provider → 不弹框。
        func canRun(_ id: String) -> Bool { s.isEnabled(id) && (allowsKeychainAccess || !needsKeychain(id)) }

        await withTaskGroup(of: [RateLimitSnapshot].self) { group in
            if canRun("codex") {
                group.addTask { [await CodexRateLimitReader().read(now: now)] }
            }
            if canRun("claude-code") {
                let source = s.dataSource(for: "claude-code")
                group.addTask { [await readClaude(source: source, now: now)] }
            }
            if canRun("cursor") {
                group.addTask { [await CursorRateLimitReader().read(now: now)] }
            }
            if canRun("qoder") {
                // 1 或 2 个快照：双登录不同账号时 Work / IDE 各查各的（issue #4）
                group.addTask { await QoderRateLimitReader().readAll(now: now) }
            }
            if canRun("qwen-work") {
                group.addTask { [await readQwenWork(now: now)] }
            }
            if canRun("workbuddy") {
                group.addTask { [await WorkBuddyRateLimitReader().read(now: now)] }
            }
            for await snaps in group {
                store(snaps)
            }
        }
    }

    /// 单个逻辑开关立即采一次（设置里刚打开开关时用，免得用户干等 10 分钟）。
    /// 这是用户主动动作 → 允许碰钥匙串。
    static func refreshOne(_ logicalId: String, now: Date = Date()) async {
        allowsKeychainAccess = true
        let snap: RateLimitSnapshot?
        switch logicalId {
        case "codex":       snap = await CodexRateLimitReader().read(now: now)
        case "claude-code": snap = await readClaude(source: RateLimitSettings.shared.dataSource(for: "claude-code"), now: now)
        case "cursor":      snap = await CursorRateLimitReader().read(now: now)
        case "qoder":
            // 用户主动点「重试 / 刷新」→ 立刻解除 401 退避，别让他等到下一个退避窗口
            QoderRateLimitReader.clearBackoff()
            store(await QoderRateLimitReader().readAll(now: now))
            return
        case "qwen-work":   snap = await readQwenWork(now: now, force: true)
        case "workbuddy":   snap = await WorkBuddyRateLimitReader().read(now: now)
        default:            snap = nil
        }
        if let snap { store([snap]) }
    }

    /// 千问办公额度快照（v0.3.38）：每日 / 周期 / 长期三类，各自「已用/额度 · 到期」（spec 0910 §3.2 A）。
    ///
    /// - 三类全走桌面令牌；有分母就给百分比（套色档），没分母（充值包、活动多送）就中性色显示「剩 X」。
    /// - 「今日已用」不再做主列表药丸：它靠网页令牌，与三类额度是两条线，只在详情页 Hero 显示。
    /// - 区头右侧 `headline` = 三类之和 = 官方「剩余可用」。
    private static func readQwenWork(now: Date = Date(), force: Bool = false) async -> RateLimitSnapshot {
        let store = QwenWorkBillingStore.shared
        let precise = await MainActor.run { RateLimitSettings.shared.qwenWorkPreciseMode }
        _ = await store.refresh(now: now, force: force, preciseMode: precise)
        let quota = await store.quota(now: now)
        await MainActor.run {
            QwenWorkWebSessionStatus.shared.update(quota.webSession, todaySpent: quota.todaySpent)
        }
        let windows = quota.categories.map { cat -> RateLimitWindow in
            let notes = cat.packs.map { pack -> String in
                var parts = [pack.title]
                if let g = pack.grant { parts.append("额度 \(QwenWorkBillingStore.formatCredits(g))") }
                if let g = pack.grant { parts.append("已用 \(QwenWorkBillingStore.formatCredits(max(0, g - pack.remaining)))") }
                parts.append("剩 \(QwenWorkBillingStore.formatCredits(pack.remaining))")
                return parts.joined(separator: " · ")
            }
            if let grant = cat.grant, grant > 0, let used = cat.used {
                // 药丸里不用千分位、整数不带小数：三颗并排只有 340pt，「63/2,000」会被截成「63/2,0…」（9/12 验收实拍）
                let ratio = "\(Self.compact(used))/\(Self.compact(grant))"
                return RateLimitWindow(
                    kind: cat.id, label: cat.label, usedPercent: min(100, used / grant * 100),
                    resetsAt: cat.resetsAt, used: used, total: grant,
                    valueText: "已用 " + ratio, resetVerb: cat.resetVerb, notes: notes)
            }
            return RateLimitWindow(
                kind: cat.id, label: cat.label, usedPercent: 0, resetsAt: cat.resetsAt,
                severity: neutralSeverity,
                valueText: "剩 " + Self.compact(cat.remaining),
                resetVerb: cat.resetVerb, notes: notes)
        }
        let headline = quota.remainingTotal.map { "剩余 \(QwenWorkBillingStore.formatCredits($0)) 积分" }
        return RateLimitSnapshot(
            providerId: "qwen-work", windows: windows, planType: quota.planName, capturedAt: now,
            error: windows.isEmpty ? (quota.error ?? .network) : nil,
            sourceLabel: "千问办公", headline: headline)
    }

    /// 药丸用的紧凑数字：整数不带小数、不加千分位（"63" / "2000" / "1937.02"）。详情页小字仍用 `formatCredits`。
    static func compact(_ v: Double) -> String {
        let rounded = v.rounded()
        if abs(v - rounded) < 0.005 { return String(Int(rounded)) }
        return String(format: "%.2f", v)
    }

    /// 精确模式开关（设置页子行）。关掉时清网页令牌缓存与退避；开时立刻采一次（会弹一次 Chrome 钥匙串框）。
    static func setQwenWorkPreciseMode(_ on: Bool) {
        RateLimitSettings.shared.setQwenWorkPreciseMode(on)
        Task {
            if !on { await QwenWorkBillingStore.shared.clearWebToken() }
            await refreshOne("qwen-work")
        }
    }

    /// Chrome 授权被拒后的「重新授权」：解除退避并立刻再试一次。
    static func retryQwenWorkChromeAuthorization() {
        Task {
            await QwenWorkBillingStore.shared.retryChromeAuthorization()
            await refreshOne("qwen-work")
        }
    }

    /// 金额型窗口用的中性色档：没有分母就没有「用了多少比例」，套绿/黄/红是无中生有。
    static let neutralSeverity = "neutral"

    /// Claude 按用户选中的数据源分派——**严格按选择走，绝不跨线路回落**：
    /// - `statusline`（默认）：只读注入产生的额度文件，**零钥匙串、零起进程**。读不到就读不到
    ///   （Claude 还没往文件写），**绝不回落到 OAuth**——否则用户选了「零钥匙串」却被弹授权框（就是这个 bug）。
    /// - `cli`：只抄 `claude -p /usage`，零钥匙串。同样不回落。
    /// - `oauth`：读钥匙串 token 打官方 API（用户明确选了这条要授权的路）。
    private static func readClaude(source: String, now: Date) async -> RateLimitSnapshot {
        switch source {
        case "statusline": return ClaudeStatuslineReader().read(now: now)
        case "cli":        return ClaudeCLIReader().read(now: now)
        default:           return await ClaudeOAuthUsageReader().read(now: now)
        }
    }

    /// 关闭逻辑开关时清掉对应快照（Qoder 清三个）。
    static func clear(_ logicalId: String) {
        let ids = logicalId == "qoder" ? QoderRateLimitReader.providerIds : [logicalId]
        for id in ids { RateLimitStore.shared.remove(id) }
    }

    /// 取消授权/重置：关开关 + 清已配置标记 + 清快照 + 清 reader 缓存 +（Claude）撤 statusline 注入。
    /// 之后再开启会重新走引导 + 重新授权。
    static func revoke(_ logicalId: String) {
        let s = RateLimitSettings.shared
        s.setEnabled(logicalId, false)
        s.clearConfigured(logicalId)
        clear(logicalId)
        switch logicalId {
        case "claude-code":
            ClaudeOAuthUsageReader.clearCache()
            StatuslineConfigurator.deconfigure()
        case "qoder":
            QoderRateLimitReader.clearCache()
        case "qwen-work":
            s.setQwenWorkPreciseMode(false)
            Task {
                await QwenWorkBillingStore.shared.clearAuthCache()
                await QwenWorkBillingStore.shared.clearWebToken()
                await MainActor.run { QwenWorkWebSessionStatus.shared.update(.off, todaySpent: nil) }
            }
        default: break
        }
    }

    /// 一个 reader 的产出落库；Qoder 组走 `storeQoder`，其余原样写入。
    private static func store(_ snaps: [RateLimitSnapshot]) {
        if snaps.first?.providerId.hasPrefix("qoder") == true {
            storeQoder(snaps)
            return
        }
        for snap in snaps {
            recordHistory(snap, logical: snap.providerId)
            RateLimitStore.shared.put(snap)
        }
    }

    /// Qoder 快照落库：**各写各的，绝不跨行复制**。
    ///
    /// ⚠️ v0.3.37 改（外部用户 2026-08-28 报「Qoder CLI 能用却显示登录凭证已失效」）：
    /// 老版本在「只有一份凭证」时把那**一个**快照铺到 `qoder-cli` 和 `qoder-ide` 两行——
    /// 于是 QoderWork 凭证 401 的失败，被同时写成了「Qoder CLI 登录凭证已失效」。
    /// 现在 reader 恒返回两个各归各的快照（见 `QoderRateLimitReader.readAll`），这里只负责原样落库。
    ///
    /// 历史仍**分池**记（"qoder" / "qoder-ide"）：两个账号的数值混在一个池里会来回踩，
    /// 每轮刷新都被记成一次假变化（issue #4 的老教训，别改回去）。
    private static func storeQoder(_ snaps: [RateLimitSnapshot]) {
        purgeRetiredQoderWork()
        for snap in snaps {
            recordHistory(snap, logical: snap.providerId == "qoder-ide" ? "qoder-ide" : "qoder")
            RateLimitStore.shared.put(snap)
        }
    }

    /// v0.3.33 下架 QoderWork 时没清缓存里的旧快照，`rate-limit-snapshot.json` 至今可能还留着一条
    /// `qoder-work`（外部报告人机器上是 2026-08-14 那条）。它不对应任何在售 provider，
    /// 只会让人以为还有个来源在活动。每进程清一次即可。
    private static var purgedQoderWork = false
    private static func purgeRetiredQoderWork() {
        guard !purgedQoderWork else { return }
        purgedQoderWork = true
        RateLimitStore.shared.remove("qoder-work")
    }

    /// 额度历史流水（v0.3.26）：所有 provider 的额度池，变化才落一行（0717 定稿）。
    /// ⚠️ 必须在 Qoder 多份复制**前**、以账号级逻辑 id 记一次，否则一次变化写多行重复。
    /// 失败快照（error != nil）由 QuotaHistoryStore 内部拦截，不记陈旧数据。
    private static func recordHistory(_ snap: RateLimitSnapshot, logical logicalId: String) {
        Task.detached {
            await QuotaHistoryStore.shared.record(provider: logicalId, snapshot: snap)
        }
    }
}
