import XCTest
@testable import PeachyPet

final class HookEventTypeInternalResultTests: XCTestCase {
    func testInternalResultRawValue() {
        XCTAssertEqual(HookEventType.internalResult.rawValue, "InternalResult")
    }

    func testInternalResultDecodesFromRawValue() {
        let decoded = HookEventType(rawValue: "InternalResult")
        XCTAssertEqual(decoded, .internalResult)
    }

    func testInternalResultIsInternalResult() {
        XCTAssertTrue(HookEventType.internalResult.isInternalResult)
    }

    func testNoOtherTypeIsInternalResult() {
        let nonInternal: [HookEventType] = [
            .stop, .taskCompleted, .userPromptSubmit, .sessionStart, .sessionEnd,
            .notification, .permissionRequest, .preToolUse, .postToolUse,
        ]
        for type in nonInternal {
            XCTAssertFalse(type.isInternalResult, "\(type) should not be internalResult")
        }
    }
}
