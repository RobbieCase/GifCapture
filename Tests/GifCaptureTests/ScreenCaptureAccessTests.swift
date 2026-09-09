import XCTest
import ScreenCaptureKit
@testable import GifCapture

@MainActor
final class ScreenCaptureAccessTests: XCTestCase {
    func testSuccessfulCaptureLookupDoesNotRequireCoreGraphicsApproval() async throws {
        let access = ScreenCaptureAccess(loadDisplays: { [] })
        let displays = try await access.displaysForRecording()
        XCTAssertNotNil(displays)
        XCTAssertTrue(access.hasVerifiedAccess)
        XCTAssertFalse(access.isChecking)
    }

    func testDeniedAttemptCanSucceedAfterPermissionChanges() async throws {
        var denied = true
        let access = ScreenCaptureAccess {
            if denied {
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
            }
            return []
        }
        do {
            _ = try await access.displaysForRecording()
            XCTFail("Expected the capture API's denial")
        } catch {
            XCTAssertTrue(ScreenCaptureAccess.isPermissionDenied(error))
        }
        XCTAssertFalse(access.isChecking)
        XCTAssertFalse(access.hasVerifiedAccess)
        denied = false
        let displays = try await access.displaysForRecording()
        XCTAssertNotNil(displays)
        XCTAssertTrue(access.hasVerifiedAccess)
    }

    func testConcurrentRecordRequestsDoNotDuplicatePermissionRequests() async throws {
        var calls = 0
        var resumeLookup: CheckedContinuation<[SCDisplay], Error>?
        let access = ScreenCaptureAccess {
            calls += 1
            return try await withCheckedThrowingContinuation { resumeLookup = $0 }
        }
        let first = Task { try await access.displaysForRecording() }
        while resumeLookup == nil { await Task.yield() }
        let second = try await access.displaysForRecording()
        XCTAssertNil(second)
        XCTAssertEqual(calls, 1)
        resumeLookup?.resume(returning: [])
        let displays = try await first.value
        XCTAssertNotNil(displays)
        XCTAssertFalse(access.isChecking)
    }

    func testOtherCaptureErrorsAreNotReportedAsPermissionDenials() {
        XCTAssertFalse(ScreenCaptureAccess.isPermissionDenied(
            NSError(domain: SCStreamErrorDomain, code: SCStreamError.failedToStart.rawValue)))
        XCTAssertFalse(ScreenCaptureAccess.isPermissionDenied(
            NSError(domain: "Other", code: SCStreamError.userDeclined.rawValue)))
    }

    func testPreviouslyVerifiedAccessIsRecheckedAndCanBeRevoked() async throws {
        var denied = false
        let access = ScreenCaptureAccess {
            if denied {
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
            }
            return []
        }
        _ = try await access.displaysForRecording()
        XCTAssertTrue(access.hasVerifiedAccess)
        denied = true
        do {
            _ = try await access.displaysForRecording()
            XCTFail("A previous grant must not bypass the capture API")
        } catch {
            XCTAssertTrue(ScreenCaptureAccess.isPermissionDenied(error))
        }
        XCTAssertFalse(access.hasVerifiedAccess)
        XCTAssertFalse(access.isChecking)
    }
}
