import XCTest
import Foundation
@testable import GifCapture

final class RecordingZoomStateTests: XCTestCase {
    func testLockedCenterStaysFixedAndSurvivesZoomOut() {
        var state = RecordingZoomState()
        state.update(following: false, locking: true, cursor: CGPoint(x: 0.2, y: 0.3))
        XCTAssertTrue(state.active)
        XCTAssertEqual(state.anchor, CGPoint(x: 0.2, y: 0.3))
        state.update(following: false, locking: true, cursor: CGPoint(x: 0.8, y: 0.9))
        XCTAssertEqual(state.anchor, CGPoint(x: 0.2, y: 0.3))
        state.update(following: false, locking: false, cursor: .zero)
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.anchor, CGPoint(x: 0.2, y: 0.3))
        state.update(following: false, locking: true, cursor: CGPoint(x: 0.7, y: 0.6))
        XCTAssertEqual(state.anchor, CGPoint(x: 0.7, y: 0.6))
    }

    func testLockedZoomTakesPriorityAndReturnsToFollowing() {
        var state = RecordingZoomState()
        state.update(following: true, locking: false, cursor: .zero)
        XCTAssertTrue(state.active)
        XCTAssertEqual(state.anchor, nil)
        state.update(following: true, locking: true, cursor: CGPoint(x: 0.4, y: 0.5))
        XCTAssertEqual(state.anchor, CGPoint(x: 0.4, y: 0.5))
        state.update(following: true, locking: false, cursor: CGPoint(x: 0.9, y: 0.9))
        XCTAssertTrue(state.active)
        XCTAssertEqual(state.anchor, nil)
        state.update(following: false, locking: false, cursor: .zero)
        XCTAssertFalse(state.active)
    }

    func testCursorOutsideCaptureClampsToEdge() {
        var state = RecordingZoomState()
        state.update(following: false, locking: true, cursor: CGPoint(x: -2, y: 3))
        XCTAssertEqual(state.anchor, CGPoint(x: 0, y: 1))
    }

    func testLockedZoomPreferencesPersistWithoutChangingMovingZoom() {
        let name = "GifCapture.LockedZoomTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = AppSettings.load(from: defaults)
        XCTAssertFalse(settings.lockedZoomEnabled)
        let movingBinding = settings.zoomBinding
        settings.lockedZoomEnabled = true
        settings.lockedZoomBinding = RecordingBinding(keyCode: 40, modifiers: [], keyName: "K")
        settings.save(to: defaults)
        let loaded = AppSettings.load(from: defaults)
        XCTAssertTrue(loaded.lockedZoomEnabled)
        XCTAssertEqual(loaded.lockedZoomBinding, settings.lockedZoomBinding)
        XCTAssertEqual(loaded.zoomBinding, movingBinding)
        XCTAssertTrue(loaded.zoomEnabled)
    }
}
