import XCTest
import AppKit
@testable import GifCapture

final class RecordingEffectSettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "GifCapture.EffectsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testLegacyClickPreferencesMigrateToCheckbox() {
        withDefaults { defaults in
            for mode in ["", "off", "unrecognized"] {
                defaults.set(mode, forKey: "clickIndicatorMode")
                let settings = AppSettings.load(from: defaults)
                XCTAssertFalse(settings.clickIndicatorEnabled)
                XCTAssertEqual(settings.clickIndicatorMode, .everyClick)
                XCTAssertTrue(settings.zoomEnabled)
                XCTAssertTrue(settings.drawEnabled)
            }
            for mode in ["everyClick", "modifierClick", "commandClick", "optionClick", "controlClick", "shiftClick"] {
                defaults.set(mode, forKey: "clickIndicatorMode")
                XCTAssertTrue(AppSettings.load(from: defaults).clickIndicatorEnabled)
            }
        }
    }

    func testDisabledEffectsStayOffAndRememberSelectionsAfterReload() {
        withDefaults { defaults in
            var settings = AppSettings.load(from: defaults)
            settings.zoomEnabled = false
            settings.drawEnabled = false
            settings.clickIndicatorEnabled = false
            settings.clickIndicatorMode = .modifierClick
            settings.save(to: defaults)
            settings = AppSettings.load(from: defaults)
            XCTAssertFalse(settings.zoomIsActive(with: settings.zoomModifier.eventFlag))
            XCTAssertFalse(settings.drawIsActive(with: settings.drawModifier.eventFlag, penLocked: true))
            XCTAssertFalse(settings.showsClickIndicator(with: settings.clickIndicatorModifier.eventFlag))
            XCTAssertEqual(settings.clickIndicatorMode, .modifierClick)

            settings.zoomEnabled = true
            settings.drawEnabled = true
            settings.clickIndicatorEnabled = true
            settings.save(to: defaults)
            settings = AppSettings.load(from: defaults)
            XCTAssertTrue(settings.zoomIsActive(with: settings.zoomModifier.eventFlag))
            XCTAssertTrue(settings.drawIsActive(with: [], penLocked: true))
            XCTAssertTrue(settings.showsClickIndicator(with: settings.clickIndicatorModifier.eventFlag))
            XCTAssertFalse(settings.showsClickIndicator(with: []))
            settings.clickIndicatorMode = .everyClick
            XCTAssertTrue(settings.showsClickIndicator(with: []))
        }
    }
}
