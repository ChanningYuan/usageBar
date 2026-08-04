import XCTest
@testable import usageBarProviders

final class QoderUsageEnvGateTests: XCTestCase {
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
