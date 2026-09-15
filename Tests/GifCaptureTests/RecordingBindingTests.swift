import XCTest
import AppKit
@testable import GifCapture

final class RecordingBindingTests: XCTestCase {
    func testPlainKeyAndChordRequireHoldAndMatchingModifiers() {
        let plain = RecordingBinding(keyCode: 6, modifiers: [], keyName: "Z")
        XCTAssertFalse(plain.matches(flags: []))
        XCTAssertTrue(plain.matches(flags: [.capsLock], keyHeld: true))
        XCTAssertFalse(plain.matches(flags: [.command], keyHeld: true))
        let chord = RecordingBinding(keyCode: 2, modifiers: [.shift, .command], keyName: "D")
        XCTAssertTrue(chord.matches(flags: [.shift, .command], keyHeld: true))
        XCTAssertFalse(chord.matches(flags: [.shift], keyHeld: true))
        XCTAssertFalse(chord.matches(flags: [.shift, .command], keyHeld: false))
    }

    func testModifierChordAndPhysicalKeyIdentity() {
        let chord = RecordingBinding(modifiers: [.control, .option])
        XCTAssertTrue(chord.matches(flags: [.control, .option, .shift]))
        XCTAssertFalse(chord.matches(flags: [.control]))
        XCTAssertFalse(chord.matches(flags: []))
        XCTAssertEqual(RecordingBinding(keyCode: 6, modifiers: .command, keyName: "Z"),
                       RecordingBinding(keyCode: 6, modifiers: .command, keyName: "Y"))
    }

    func testLegacyMigrationPersistenceAndDisabledEffects() {
        let name = "GifCapture.BindingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("option", forKey: "zoomModifier")
        defaults.set("command", forKey: "drawModifier")
        defaults.set("control", forKey: "clickIndicatorModifier")
        defaults.set("modifierClick", forKey: "clickIndicatorMode")
        var settings = AppSettings.load(from: defaults)
        XCTAssertEqual(settings.zoomBinding, RecordingBinding(.option))
        XCTAssertEqual(settings.drawBinding, RecordingBinding(.command))
        XCTAssertEqual(settings.clickIndicatorBinding, RecordingBinding(.control))
        settings.zoomBinding = RecordingBinding(keyCode: 6, modifiers: [], keyName: "Z")
        settings.drawBinding = RecordingBinding(keyCode: 2, modifiers: .shift, keyName: "D")
        settings.clickIndicatorBinding = RecordingBinding(keyCode: 8, modifiers: [], keyName: "C")
        settings.save(to: defaults)
        let loaded = AppSettings.load(from: defaults)
        XCTAssertEqual(loaded.zoomBinding, settings.zoomBinding)
        XCTAssertEqual(loaded.drawBinding, settings.drawBinding)
        XCTAssertEqual(loaded.clickIndicatorBinding, settings.clickIndicatorBinding)
        XCTAssertTrue(loaded.zoomIsActive(with: [], keyHeld: true))
        XCTAssertFalse(loaded.zoomIsActive(with: [], keyHeld: false))
        XCTAssertTrue(loaded.drawIsActive(with: .shift, penLocked: false, keyHeld: true))
        XCTAssertFalse(loaded.drawIsActive(with: .shift, penLocked: false, keyHeld: false))
        XCTAssertTrue(loaded.showsClickIndicator(with: [], keyHeld: true))
        XCTAssertFalse(loaded.showsClickIndicator(with: [], keyHeld: false))
        settings.zoomEnabled = false
        settings.drawEnabled = false
        settings.clickIndicatorEnabled = false
        XCTAssertFalse(settings.zoomIsActive(with: [], keyHeld: true))
        XCTAssertFalse(settings.drawIsActive(with: .shift, penLocked: true, keyHeld: true))
        XCTAssertFalse(settings.showsClickIndicator(with: [], keyHeld: true))
        defaults.set(Data("invalid".utf8), forKey: "zoomBinding")
        XCTAssertEqual(AppSettings.load(from: defaults).zoomBinding, RecordingBinding(.option))
    }
}
