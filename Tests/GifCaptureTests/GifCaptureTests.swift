import Foundation
import XCTest
@testable import GifCapture

final class GifCaptureTests: XCTestCase {
    func testUniqueOutputURLAddsSuffixInsteadOfOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GifCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = GifConverter.uniqueOutputURL(in: directory, at: date)
        try Data([1]).write(to: first)
        let second = GifConverter.uniqueOutputURL(in: directory, at: date)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.deletingPathExtension().lastPathComponent.hasSuffix(" 2"))
    }

    func testCommitRefusesToOverwriteExistingCapture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GifCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("partial")
        let output = directory.appendingPathComponent("capture.gif")
        try Data([1, 2, 3]).write(to: temporary)
        try Data([9]).write(to: output)

        XCTAssertThrowsError(try GifConverter.commit(temporary, to: output))
        XCTAssertEqual(try Data(contentsOf: output), Data([9]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testCropGeometryAccountsForLetterboxing() {
        let container = CGRect(x: 0, y: 0, width: 632, height: 355)
        let content = CropGeometry.contentRect(
            container: container,
            sourceSize: CGSize(width: 400, height: 400)
        )
        XCTAssertEqual(content.width, 355, accuracy: 0.001)
        XCTAssertEqual(content.minX, 138.5, accuracy: 0.001)

        let selection = CGRect(x: content.minX + 35.5, y: 35.5, width: 284, height: 284)
        let normalized = CropGeometry.normalize(selection, within: content)
        let restored = CropGeometry.denormalize(normalized, within: content)
        XCTAssertEqual(restored.minX, selection.minX, accuracy: 0.001)
        XCTAssertEqual(restored.minY, selection.minY, accuracy: 0.001)
        XCTAssertEqual(restored.width, selection.width, accuracy: 0.001)
        XCTAssertEqual(restored.height, selection.height, accuracy: 0.001)
    }

    func testStoppingAnIdleRecorderFailsClearly() async {
        let recorder = ScreenRecorder()
        do {
            _ = try await recorder.stop()
            XCTFail("Expected stop to fail when no stream is active")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Not recording"))
        }
    }
}
