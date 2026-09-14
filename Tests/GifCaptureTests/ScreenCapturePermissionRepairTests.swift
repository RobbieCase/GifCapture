import XCTest
@testable import GifCapture

final class ScreenCapturePermissionRepairTests: XCTestCase {
    func testRepairRegistersBeforeResettingOnlyGifCapture() throws {
        var invocations: [(String, [String])] = []
        try ScreenCapturePermissionRepair.runRepair(appPath: "/Applications/GifCapture.app") {
            invocations.append(($0, $1))
        }
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].0, ScreenCapturePermissionRepair.registrationTool)
        XCTAssertEqual(invocations[0].1, ["-f", "/Applications/GifCapture.app"])
        XCTAssertEqual(invocations[1].0, "/usr/bin/tccutil")
        XCTAssertEqual(invocations[1].1, ["reset", "ScreenCapture", "com.robbiecase.gifcapture"])
    }

    func testRegistrationFailurePreventsReset() {
        var calls = 0
        XCTAssertThrowsError(try ScreenCapturePermissionRepair.runRepair(appPath: "/Applications/GifCapture.app") { _, _ in
            calls += 1
            throw NSError(domain: "RegistrationFailed", code: 1)
        })
        XCTAssertEqual(calls, 1)
    }

    func testResetFailureIsNotReportedAsSuccess() {
        var calls = 0
        XCTAssertThrowsError(try ScreenCapturePermissionRepair.runRepair(appPath: "/Applications/GifCapture.app") { _, _ in
            calls += 1
            if calls == 2 { throw NSError(domain: "ResetFailed", code: 1) }
        })
        XCTAssertEqual(calls, 2)
    }
}
