import XCTest
@testable import EmojiBako

final class ICloudUsageStoreTests: XCTestCase {
    func testMapsKeyValueStoreChangeReasons() {
        func reason(_ value: Int) -> UsageSync.CloudChangeReason? {
            ICloudUsageSyncConnection.reason(from: [NSUbiquitousKeyValueStoreChangeReasonKey: value])
        }
        XCTAssertEqual(reason(NSUbiquitousKeyValueStoreServerChange), .serverChange)
        XCTAssertEqual(reason(NSUbiquitousKeyValueStoreInitialSyncChange), .initialSync)
        XCTAssertEqual(reason(NSUbiquitousKeyValueStoreQuotaViolationChange), .quotaViolation)
        XCTAssertEqual(reason(NSUbiquitousKeyValueStoreAccountChange), .accountChange)
    }

    func testUnknownOrMissingReasonIsNil() {
        XCTAssertNil(ICloudUsageSyncConnection.reason(from: [NSUbiquitousKeyValueStoreChangeReasonKey: 99]))
        XCTAssertNil(ICloudUsageSyncConnection.reason(from: [:]))
        XCTAssertNil(ICloudUsageSyncConnection.reason(from: nil))
    }

    func testComputerNameIsAvailable() {
        XCTAssertFalse(ComputerNameMonitor.current().isEmpty)
    }
}
