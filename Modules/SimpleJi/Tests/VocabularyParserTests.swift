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

    func testPartOfSpeechBelongsToMeaningAcrossImportFormats() {
        for input in ["conversation n.对话", "conversation n. 对话", "conversation n.\t对话",
                      "conversation n. - 对话", "conversation — n.对话", "conversation\tn.对话"] {
            let result = VocabularyParser.parse(input)
            XCTAssertTrue(result.unrecognized.isEmpty, input)
            XCTAssertEqual(result.entries.first?.english, "conversation", input)
            XCTAssertEqual(result.entries.first?.normalizedEnglish, "conversation", input)
            XCTAssertEqual(result.entries.first?.chinese, "n.对话", input)
            if let entry = result.entries.first {
                XCTAssertTrue(DictationAnswerMatcher.matches("conversation", answer: entry.english), input)
                XCTAssertFalse(DictationAnswerMatcher.matches("conversation n.", answer: entry.english), input)
            }
        }
    }

    func testCommonAndCombinedPartOfSpeechLabels() {
        for label in ["n.", "v.", "vt.", "vi.", "adj.", "adv.", "pron.", "prep.", "conj.",
                      "interj.", "num.", "art.", "n./v.", "vt. & vi."] {
            let result = VocabularyParser.parse("test \(label) 测试")
            XCTAssertEqual(result.entries.first?.english, "test", label)
            XCTAssertEqual(result.entries.first?.chinese, label + "测试", label)
        }
    }

    func testPartOfSpeechDoesNotStripPhrasesOrOtherAbbreviations() {
        for term in ["ice cream", "look after", "vitamin B", "U.S.", "plan.", "a", "chapter no."] {
            let result = VocabularyParser.parse("\(term) 释义")
            XCTAssertEqual(result.entries.first?.english, term)
            XCTAssertEqual(result.entries.first?.chinese, "释义")
        }
        XCTAssertEqual(VocabularyParser.parse("n. 名词").unrecognized.count, 1)
    }
}
