import Foundation
import XCTest

@testable import TapeloopCore

final class TranscriptionSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> TranscriptionSettings {
        try JSONDecoder().decode(TranscriptionSettings.self, from: Data(json.utf8))
    }

    func testDefaultsAreParakeetAfterSaveAndOff() {
        let settings = TranscriptionSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.engine, .parakeet)
        XCTAssertEqual(settings.mode, .afterSave)
        XCTAssertTrue(settings.automatic)
    }

    func testOlderSettingsMeanAppleEngine() throws {
        let manual = try decode(#"{"enabled":true,"automatic":false,"labelSpeakers":true}"#)
        XCTAssertEqual(manual.engine, .apple)
        XCTAssertEqual(manual.mode, .manual)
        let automatic = try decode(#"{"enabled":false,"automatic":true,"labelSpeakers":false}"#)
        XCTAssertEqual(automatic.mode, .afterSave)
        XCTAssertFalse(automatic.labelSpeakers)
    }

    func testRoundTrip() throws {
        let settings = TranscriptionSettings(
            enabled: true, engine: .parakeet, mode: .live, localeID: nil, labelSpeakers: true)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionSettings.self, from: data), settings)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("automatic"))
    }

    func testManualIsNotAutomatic() {
        XCTAssertFalse(TranscriptionSettings(mode: .manual).automatic)
        XCTAssertTrue(TranscriptionSettings(mode: .live).automatic)
    }

    func testDefaultModelEntry() {
        let model = TranscriptionModel.default
        XCTAssertEqual(model.sha256.count, 64)
        XCTAssertEqual(model.url.host, "github.com")
        XCTAssertTrue(model.url.path.hasSuffix(model.fileName))
        XCTAssertGreaterThan(model.size, 700_000_000)
    }
}
