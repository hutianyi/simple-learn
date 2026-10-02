import XCTest
@testable import DictationApp

final class MoBackupTests: XCTestCase {
    func testLegacySettingsRoundTripPreservesEverySettingAndDoesNotChangeOtherSuite() throws {
        let sourceName = "MoSource-\(UUID())", targetName = "MoTarget-\(UUID())"
        let source = UserDefaults(suiteName: sourceName)!, target = UserDefaults(suiteName: targetName)!
        defer { source.removePersistentDomain(forName: sourceName); target.removePersistentDomain(forName: targetName) }
        source.set("苹果\nhello, world", forKey: "dictation.input")
        source.set(true, forKey: "dictation.shuffle")
        source.set(false, forKey: "dictation.automaticTiming")
        source.set(0.5, forKey: "dictation.rate")
        source.set(20, forKey: "dictation.repeatAfter")
        source.set(45, forKey: "dictation.advanceAfter")
        target.set("other-data", forKey: "untouched")
        let original = MoBackup.snapshot(defaults: source)
        let restored = try MoBackup.decode(MoBackup.encode(original))
        restored.apply(defaults: target)
        XCTAssertEqual(MoBackup.snapshot(defaults: target).settings, original.settings)
        XCTAssertEqual(target.string(forKey: "untouched"), "other-data")
    }

    func testRejectsWrongAppAndInvalidTiming() throws {
        let timing = MoBackup.Settings(inputText: "test", shuffleWords: false, speechRate: 0.42,
            repeatAfterSeconds: 30, advanceAfterSeconds: 30)
        XCTAssertThrowsError(try MoBackup.decode(MoBackup.encode(MoBackup(settings: timing))))
        let tooLong = MoBackup.Settings(inputText: "test", shuffleWords: false, speechRate: 0.42,
            repeatAfterSeconds: 15, advanceAfterSeconds: 610)
        XCTAssertThrowsError(try MoBackup.decode(MoBackup.encode(MoBackup(settings: tooLong))))
        var wrong = MoBackup.snapshot(); wrong.app = "SimpleSuan"
        XCTAssertThrowsError(try MoBackup.decode(MoBackup.encode(wrong)))
    }

    func testOlderBackupWithoutTimingModeDefaultsToAutomatic() throws {
        let settings = MoBackup.Settings(inputText: "orange tree", shuffleWords: false, speechRate: 0.42,
            repeatAfterSeconds: 15, advanceAfterSeconds: 60)
        let data = try MoBackup.encode(MoBackup(settings: settings))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("automaticTiming"))
        let restored = try MoBackup.decode(data)
        let name = "MoLegacy-\(UUID())"
        let target = UserDefaults(suiteName: name)!
        defer { target.removePersistentDomain(forName: name) }
        target.set(false, forKey: "dictation.automaticTiming")
        restored.apply(defaults: target)
        XCTAssertTrue(target.bool(forKey: "dictation.automaticTiming"))
    }

}
