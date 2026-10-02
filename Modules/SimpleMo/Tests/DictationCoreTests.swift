import XCTest
@testable import DictationApp

final class DictationCoreTests: XCTestCase {
    func testResultsDefaultToCorrectAndAllowIndividualChanges() {
        var results = DictationResults(words: ["苹果", "look after", "苹果"])
        XCTAssertEqual(results.correctCount, 3)
        XCTAssertTrue(results.canConfirm)
        results.setMark(.correct, at: 0)
        results.setMark(.incorrect, at: 1)
        XCTAssertTrue(results.canConfirm)
        results.setMark(.incorrect, at: 2)
        XCTAssertTrue(results.canConfirm)
        XCTAssertEqual(results.correctCount, 1)
        XCTAssertEqual(results.incorrectWords, ["look after", "苹果"])
    }

    func testAllCorrectThenIndividualCorrectionsAndRepeatedRetry() {
        let original = ["苹果", "look after", "苹果", "read a book"]
        var results = DictationResults(words: original)
        results.markAllCorrect()
        XCTAssertTrue(results.canConfirm)
        XCTAssertEqual(results.correctCount, 4)
        XCTAssertTrue(results.incorrectWords.isEmpty)
        results.setMark(.incorrect, at: 0)
        results.setMark(.incorrect, at: 2)
        XCTAssertEqual(results.incorrectWords, ["苹果", "苹果"])
        XCTAssertEqual(results.words, original)

        var retry = DictationResults(words: results.incorrectWords)
        XCTAssertEqual(retry.correctCount, 2)
        XCTAssertTrue(retry.canConfirm)
        retry.markAllCorrect()
        retry.setMark(.incorrect, at: 1)
        XCTAssertEqual(retry.incorrectWords, ["苹果"])
        retry.setMark(.correct, at: 1)
        XCTAssertTrue(retry.incorrectWords.isEmpty)
        XCTAssertTrue(retry.canConfirm)
        XCTAssertFalse(DictationResults().canConfirm)
    }

    func testParsingAndSpeechText() {
        let text = "苹果\n认真\t美丽\numbrella\twonderful\nbook"
        XCTAssertEqual(DictationCore.parseWords(from: text), ["苹果", "认真", "美丽", "umbrella", "wonderful", "book"])
        XCTAssertEqual(DictationCore.language(for: "认真"), .chinese)
        XCTAssertEqual(DictationCore.language(for: "umbrella"), .english)
        XCTAssertEqual(DictationCore.repeatedSpeechText(for: "认真"), "认真，认真")
        XCTAssertEqual(DictationCore.repeatedSpeechText(for: "book"), "book. book")
    }

    func testOnlyNewlinesAndTabsSplitItemsWhileSpacesAndPunctuationStay() {
        XCTAssertEqual(DictationCore.parseWords(from: "  look after  \n a  little "), ["look after", "a  little"])
        XCTAssertEqual(DictationCore.parseWords(from: "苹果 香蕉\tlook after, wonderful world；read a book;go home，good morning\r\nnext line"),
                       ["苹果 香蕉", "look after, wonderful world；read a book;go home，good morning", "next line"])
        XCTAssertEqual(DictationCore.parseWords(from: " \n\t \r\n"), [])
        XCTAssertEqual(DictationCore.parseWords(from: "look after\nlook after"), ["look after", "look after"])
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

    func testAutomaticTimingForEnglishChineseAndMixedContent() {
        let examples: [(String, Int)] = [
            ("orange tree", 60), ("tea leaves", 60), ("favourite plant", 70),
            ("water the plants", 80), ("grow tomatoes", 70),
            ("make information cards", 90), ("design a report", 80),
            ("open at 9 o’clock", 90), ("close at 4 o’clock", 90),
            ("它是一棵橙子树。", 100), ("谁喜欢草莓？我！", 90),
            ("这是什么？这是一棵胡萝卜苗。", 120),
            ("这个地方是用来种蔬菜的。", 120),
            ("蜜蜂帮助植物，我们也来帮助植物吧。", 140),
            ("今天学 orange tree。", 80), ("苹果，香蕉；", 80),
            ("", 60), ("abc", 60), ("！ ；", 60)
        ]
        for (text, expected) in examples {
            let timing = DictationTimingConfiguration.automatic(for: text)
            XCTAssertEqual(timing.advanceAfterSeconds, expected, text)
            XCTAssertEqual(timing.remainingSecondsAfterRepeat, 30)
            XCTAssertTrue(timing.isValid)
        }
        XCTAssertEqual(DictationTimingConfiguration.automatic(for: "一二三四五六七八九").advanceAfterSeconds, 110)
        XCTAssertEqual(DictationTimingConfiguration.automatic(for: "一二三四五六七八").advanceAfterSeconds, 100)
        XCTAssertEqual(DictationTimingConfiguration.automatic(for: String(repeating: "字", count: 150)).advanceAfterSeconds, 810)
    }

    func testInitialReadingAndRereadingDoNotConsumeWritingTime() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var countdown = DictationCountdown(timing: .automatic(for: "orange tree"), startedAt: start, paused: true)
        XCTAssertEqual(countdown.update(at: start.addingTimeInterval(100)).secondsRemaining, 60)
        XCTAssertFalse(countdown.update(at: start.addingTimeInterval(100)).shouldAdvance)
        countdown.resume(at: start.addingTimeInterval(100))
        XCTAssertEqual(countdown.update(at: start.addingTimeInterval(110)).secondsRemaining, 50)
        countdown.pause(at: start.addingTimeInterval(110))
        countdown.pause(at: start.addingTimeInterval(115))
        XCTAssertEqual(countdown.update(at: start.addingTimeInterval(150)).secondsRemaining, 50)
        countdown.resume(at: start.addingTimeInterval(150))
        XCTAssertTrue(countdown.update(at: start.addingTimeInterval(170)).shouldRepeatAndWarn)
        countdown.pause(at: start.addingTimeInterval(170))
        XCTAssertFalse(countdown.update(at: start.addingTimeInterval(300)).shouldAdvance)
        countdown.resume(at: start.addingTimeInterval(300))
        XCTAssertFalse(countdown.update(at: start.addingTimeInterval(329)).shouldAdvance)
        XCTAssertTrue(countdown.update(at: start.addingTimeInterval(330)).shouldAdvance)
    }

    func testAddingTimeOnlyOnceAndResetForNextItem() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var countdown = DictationCountdown(timing: .automatic(for: "orange tree"), startedAt: start, paused: true)
        XCTAssertTrue(countdown.extend(at: start.addingTimeInterval(20)))
        XCTAssertTrue(countdown.hasExtendedTime)
        XCTAssertEqual(countdown.update(at: start.addingTimeInterval(50)).secondsRemaining, 90)
        XCTAssertFalse(countdown.extend(at: start.addingTimeInterval(30)))
        XCTAssertEqual(countdown.update(at: start.addingTimeInterval(50)).secondsRemaining, 90)
        countdown.resume(at: start.addingTimeInterval(50))
        XCTAssertTrue(countdown.update(at: start.addingTimeInterval(110)).shouldRepeatAndWarn)
        XCTAssertFalse(countdown.extend(at: start.addingTimeInterval(120)))
        XCTAssertEqual(countdown.update(at: start.addingTimeInterval(120)).secondsRemaining, 20)
        XCTAssertTrue(countdown.update(at: start.addingTimeInterval(140)).shouldAdvance)

        // A new item gets its own opportunity, including after its reminder.
        var next = DictationCountdown(timing: .automatic(for: "orange tree"), startedAt: start)
        XCTAssertFalse(next.hasExtendedTime)
        XCTAssertTrue(next.update(at: start.addingTimeInterval(30)).shouldRepeatAndWarn)
        XCTAssertTrue(next.extend(at: start.addingTimeInterval(40)))
        XCTAssertEqual(next.update(at: start.addingTimeInterval(40)).secondsRemaining, 50)
        XCTAssertTrue(next.update(at: start.addingTimeInterval(60)).shouldRepeatAndWarn)
        XCTAssertFalse(next.update(at: start.addingTimeInterval(61)).shouldRepeatAndWarn)
        XCTAssertFalse(next.extend(at: start.addingTimeInterval(70)))
        XCTAssertFalse(next.update(at: start.addingTimeInterval(89)).shouldAdvance)
        XCTAssertTrue(next.update(at: start.addingTimeInterval(90)).shouldAdvance)
    }

}
