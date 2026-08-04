import XCTest
@testable import usageBarProviders

final class QoderUsageEnvGateTests: XCTestCase {

    // MARK: - 主列表提示三态（0804 在这里翻过两次车，全部锁死）

    /// ⛔ 装了、用过、gate 没开 → **必须**给「去开启」引导。
    /// 这是最不能坏的一条：坏了用户永远不知道 token 统计可以打开（当初 Qoder CLI 归零就是这么发现的）。
    func testGateOffAlwaysOffersEnableGuide() {
        for token in [0, 12_345] {
            for hasActivity in [true, false] {
                XCTAssertEqual(
                    GateHintState.evaluate(present: true, gateEnabled: false,
                                           windowToken: token, hasLogActivityInWindow: hasActivity),
                    .notEnabled,
                    "gate 没开时无论有没有用量、有没有日志活动，都要给开启引导")
            }
        }
    }

    /// gate 开了、这个周期确实写过日志、token 却是 0 → 目标 app 没重启。
    func testGateOnButNoTokenDespiteActivityAsksForRestart() {
        XCTAssertEqual(
            GateHintState.evaluate(present: true, gateEnabled: true,
                                   windowToken: 0, hasLogActivityInWindow: true),
            .needsRestart)
    }

    /// ⛔ 回归锁：今天**没用过**这个工具时不能提示重启。
    /// 0804 验收现场：用户当天没开 QoderWork（最近日志停在 6-25），却被提示「重启 QoderWork」。
    /// 「今天没用过」和「用了但 gate 没生效」的 token 都是 0，只有日志活动能把两者分开。
    func testGateOnWithoutActivityStaysSilent() {
        XCTAssertEqual(
            GateHintState.evaluate(present: true, gateEnabled: true,
                                   windowToken: 0, hasLogActivityInWindow: false),
            .none,
            "今天没用过就是没用过，别拿重启去打扰用户")
    }

    /// 有 token = 一切正常，不提示。
    func testGateOnWithTokensShowsNothing() {
        XCTAssertEqual(
            GateHintState.evaluate(present: true, gateEnabled: true,
                                   windowToken: 31_230, hasLogActivityInWindow: true),
            .none)
    }

    /// 没装/没用过的产品，任何情况都不该出现在提示里。
    func testAbsentProductNeverHints() {
        for gateEnabled in [true, false] {
            for hasActivity in [true, false] {
                XCTAssertEqual(
                    GateHintState.evaluate(present: false, gateEnabled: gateEnabled,
                                           windowToken: 0, hasLogActivityInWindow: hasActivity),
                    .none)
            }
        }
    }

    func testManagedBlockEnablesBothSdkPrefixes() {
        XCTAssertEqual(QoderUsageEnvGate.qoderEnvName, "QODER_EXPOSE_TOKEN_USAGE")
        XCTAssertEqual(QoderUsageEnvGate.qwenWorkEnvName, "QODERCN_EXPOSE_TOKEN_USAGE")
        XCTAssertEqual(
            QoderUsageEnvGate.enabledEnvNames(
                inProfileText: QoderUsageEnvGate.managedBlock
            ),
            Set(QoderUsageEnvGate.envNames)
        )
    }

    func testLegacyQoderOnlyBlockDoesNotClaimQwenIsEnabled() {
        let legacy = """
        # BEGIN usageBar-qodercli-usage
        export QODER_EXPOSE_TOKEN_USAGE=1
        # END usageBar-qodercli-usage
        """
        let enabled = QoderUsageEnvGate.enabledEnvNames(inProfileText: legacy)

        XCTAssertTrue(QoderUsageEnvGate.allRequiredProductsEnabled(
            qoderPresent: true,
            qwenWorkPresent: false,
            enabledEnvNames: enabled
        ))
        XCTAssertFalse(QoderUsageEnvGate.allRequiredProductsEnabled(
            qoderPresent: true,
            qwenWorkPresent: true,
            enabledEnvNames: enabled
        ))
    }

    func testQwenOnlyInstallRequiresCNVariable() {
        XCTAssertFalse(QoderUsageEnvGate.allRequiredProductsEnabled(
            qoderPresent: false,
            qwenWorkPresent: true,
            enabledEnvNames: [QoderUsageEnvGate.qoderEnvName]
        ))
        XCTAssertTrue(QoderUsageEnvGate.allRequiredProductsEnabled(
            qoderPresent: false,
            qwenWorkPresent: true,
            enabledEnvNames: [QoderUsageEnvGate.qwenWorkEnvName]
        ))
    }

    func testUnmanagedExportsAreNotRemovedOrMistakenForManagedBlock() {
        let profile = """
        export QODER_EXPOSE_TOKEN_USAGE=1
        export QODERCN_EXPOSE_TOKEN_USAGE=1
        """
        XCTAssertTrue(
            QoderUsageEnvGate.enabledEnvNames(inProfileText: profile).isEmpty
        )
        XCTAssertFalse(QoderUsageEnvGate.allRequiredProductsEnabled(
            qoderPresent: false,
            qwenWorkPresent: false,
            enabledEnvNames: Set(QoderUsageEnvGate.envNames)
        ))
    }
}
