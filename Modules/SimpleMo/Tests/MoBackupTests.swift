import XCTest
@testable import DictationApp

final class MoBackupTests: XCTestCase {
    func testLegacySettingsRoundTripPreservesEverySettingAndDoesNotChangeOtherSuite() throws {
        let sourceName = "MoSource-\(UUID())", targetName = "MoTarget-\(UUID())"
        let source = UserDefaults(suiteName: sourceName)!, target = UserDefaults(suiteName: targetName)!
        defer { source.removePersistentDomain(forName: sourceName); target.removePersistentDomain(forName: targetName) }
        source.set("苹果\nhello, world", forKey: "dictation.input")
        source.set(true, forKey: "dictation.shuffle")
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
        var wrong = MoBackup.snapshot(); wrong.app = "SimpleSuan"
        XCTAssertThrowsError(try MoBackup.decode(MoBackup.encode(wrong)))
    }
}
