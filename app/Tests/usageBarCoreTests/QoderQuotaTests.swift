import XCTest
import usageBarCore

@testable import usageBarProviders

/// Qoder 额度响应解析（`QoderRateLimitReader.snapshot(fromQuota:now:)`）。
/// 两个样本都是真机实测原文：personal（2026-07-14 本机探针）、teams（2026-07-15 同事探针）。
/// 核心回归点：**percentage 字段两种量纲**（personal 0–100 / teams 0–1）——解析必须用 used/total 自算，
/// 否则 teams 用满的席位显示成 1%（v0.3.24 线上 bug）。
final class QoderQuotaTests: XCTestCase {

    private func parse(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
    }

    func testTeamsPercentageIsFractionScale() {
        // 同事 teams 账号实测：席位 6000/6000 用满，API 却回 percentage=1.0（0–1 量纲）
        let obj = parse("""
        {"userId":"019cf7c1","userType":"teams","usageType":"credits",
         "totalUsagePercentage":1.0,"isQuotaExceeded":false,"expiresAt":1784736000000,
         "userQuota":{"total":6000.0,"used":6000.0,"remaining":0.0,"percentage":1.0,"unit":"credits"},
         "orgResourcePackage":{"used":6551.0,"remaining":7449.0,"percentage":0.47,"unit":"credits","cap":14000.0,"available":true},
         "isPlanQuotaProrated":false}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.planType, "teams")
        XCTAssertEqual(snap.windows.count, 2)   // 席位套餐 + 组织资源包
        XCTAssertEqual(snap.windows[0].label, "套餐")
        XCTAssertEqual(snap.windows[0].usedPercent, 100, accuracy: 0.01)   // 不是 1
        XCTAssertEqual(snap.windows[0].detail, "6,000/6,000")
        XCTAssertEqual(snap.windows[0].resetsAt,
                       Date(timeIntervalSince1970: 1_784_736_000))         // 2026-07-23 00:00 +0800
        XCTAssertEqual(snap.windows[1].label, "资源包")
        XCTAssertEqual(snap.windows[1].usedPercent, 46.79, accuracy: 0.01) // 不是 0.47
        XCTAssertEqual(snap.windows[1].detail, "6,551/14,000")
        XCTAssertNil(snap.windows[1].resetsAt)   // 购买制，无刷新日期（expiresAt 归属套餐）
    }

    func testPersonalPercentageIsPercentScale() {
        // 2026-07-14 本机探针实测：personal 账号 percentage 是 0–100 量纲，自算结果应与其一致
        let obj = parse("""
        {"userType":"personal_standard","usageType":"credits","totalUsagePercentage":37.0,
         "userQuota":{"total":5000,"used":1850,"remaining":3150,"percentage":37,"unit":"credits"},
         "expiresAt":253402214400000}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertNil(snap.error)
        XCTAssertEqual(snap.windows.count, 1)    // personal 无 orgResourcePackage
        XCTAssertEqual(snap.windows[0].label, "月")
        XCTAssertEqual(snap.windows[0].usedPercent, 37, accuracy: 0.01)
        XCTAssertEqual(snap.windows[0].detail, "1,850/5,000")
        XCTAssertNil(snap.windows[0].resetsAt)   // year-9999 哨兵 = 永不过期
    }

    func testClaudePlanLabelFromLocalConfig() {
        // ~/.claude.json oauthAccount 明文推导付费档（2026-07-15 本机实测字段）
        func label(_ tier: [String: Any]) -> String? {
            ClaudeStatuslineReader.planLabel(fromConfig: ["oauthAccount": tier])
        }
        XCTAssertEqual(label(["organizationRateLimitTier": "default_claude_max_5x"]), "Max 5x")
        XCTAssertEqual(label(["organizationRateLimitTier": "default_claude_max_20x"]), "Max 20x")
        XCTAssertEqual(label(["organizationType": "claude_pro"]), "Pro")
        // userRateLimitTier 优先于组织档
        XCTAssertEqual(label(["userRateLimitTier": "claude_max_20x",
                              "organizationRateLimitTier": "default_claude_max_5x"]), "Max 20x")
        XCTAssertNil(label(["organizationType": "enterprise_weird"]))   // 认不出宁缺别乱标
        XCTAssertNil(ClaudeStatuslineReader.planLabel(fromConfig: [:]))
    }

    func testCommunityNoQuota() {
        // 免费版 total=0 → 无信用点额度概念
        let obj = parse("""
        {"userType":"community","userQuota":{"total":0,"used":0,"remaining":0,"percentage":0,"unit":"credits"}}
        """)
        let snap = QoderRateLimitReader.snapshot(fromQuota: obj, now: Date())
        XCTAssertEqual(snap.error, .noQuotaData)
        XCTAssertTrue(snap.windows.isEmpty)
    }
}
