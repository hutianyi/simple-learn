import XCTest
@testable import DictationApp

final class DictationCoreTests: XCTestCase {
    func testParsingAndSpeechText() {
        let text = "苹果  认真\t美丽\numbrella, wonderful；book"
        XCTAssertEqual(DictationCore.parseWords(from: text), ["苹果", "认真", "美丽", "umbrella", "wonderful", "book"])
        XCTAssertEqual(DictationCore.language(for: "认真"), .chinese)
        XCTAssertEqual(DictationCore.language(for: "umbrella"), .english)
        XCTAssertEqual(DictationCore.repeatedSpeechText(for: "认真"), "认真，认真")
        XCTAssertEqual(DictationCore.repeatedSpeechText(for: "book"), "book. book")
    }

    func testConfigurableCountdown() {
        let timing = DictationTimingConfiguration.default
        XCTAssertTrue(timing.isValid)
        XCTAssertFalse(DictationTimingConfiguration(repeatAfterSeconds: 30, advanceAfterSeconds: 30).isValid)
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var countdown = DictationCountdown(timing: timing, startedAt: startedAt)
        XCTAssertEqual(countdown.update(at: startedAt).secondsRemaining, 30)
        XCTAssertFalse(countdown.update(at: startedAt.addingTimeInterval(14.9)).shouldRepeatAndWarn)
        XCTAssertTrue(countdown.update(at: startedAt.addingTimeInterval(15)).shouldRepeatAndWarn)
        XCTAssertFalse(countdown.update(at: startedAt.addingTimeInterval(16)).shouldRepeatAndWarn)
        XCTAssertTrue(countdown.update(at: startedAt.addingTimeInterval(30)).shouldAdvance)
    }
}
