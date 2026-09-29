import XCTest
@testable import WordMemoryCards

final class VocabularyParserTests: XCTestCase {
    func testSupportedFormatsAndIgnoredMarkdown() {
        let input = """
        # Unit 1
        apple 苹果
        Apple    苹果
        - banana 香蕉
        * orange 橙子
        ice cream 冰淇淋
        look after\t照顾
        can't - 不能
        can’t — 不能
        ---

        wrong line
        """

        let result = VocabularyParser.parse(input)

        XCTAssertEqual(result.entries.count, 8)
        XCTAssertEqual(result.unrecognized.count, 1)
        XCTAssertEqual(result.entries[4].english, "ice cream")
        XCTAssertEqual(result.entries[5].english, "look after")
        XCTAssertEqual(result.entries[6].normalizedEnglish, "can't")
        XCTAssertEqual(result.entries[7].normalizedEnglish, "can't")
        XCTAssertEqual(result.unrecognized.first?.text, "wrong line")
    }

    func testEnglishNormalizationPreservesMeaningfulPunctuation() {
        XCTAssertEqual(EnglishNormalizer.normalize("  ICE   CREAM  "), "ice cream")
        XCTAssertEqual(EnglishNormalizer.normalize("can’t"), "can't")
        XCTAssertEqual(EnglishNormalizer.normalize("mother-in-law"), "mother-in-law")
    }

    func testInvalidSidesAreRejected() {
        let result = VocabularyParser.parse("123 苹果\napple 123")

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.unrecognized.count, 2)
    }
}
