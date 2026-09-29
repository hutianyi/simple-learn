import XCTest
@testable import WordMemoryCards

final class ImportAnalyzerTests: XCTestCase {
    func testDuplicateConflictAndNewEntryAreSeparated() {
        let parseResult = VocabularyParser.parse(
            """
            Apple 苹果
            apple 苹果
            APPLE 苹果；苹果公司
            banana 香蕉
            """
        )

        let analysis = ImportAnalyzer.analyze(
            parseResult: parseResult,
            existingWords: [
                ExistingWordSnapshot(
                    english: "apple",
                    normalizedEnglish: "apple",
                    chinese: "苹果"
                )
            ]
        )

        XCTAssertEqual(analysis.additions.map(\.normalizedEnglish), ["banana"])
        XCTAssertEqual(analysis.existing.count, 2)
        XCTAssertEqual(analysis.conflicts.count, 1)
        XCTAssertEqual(analysis.conflicts.first?.existingChinese, "苹果")
    }

    func testDuplicateWithinOnePasteOnlyAddsTheFirstCopy() {
        let parseResult = VocabularyParser.parse("beautiful 美丽的\nBeautiful 美丽的")
        let analysis = ImportAnalyzer.analyze(parseResult: parseResult, existingWords: [])

        XCTAssertEqual(analysis.additions.count, 1)
        XCTAssertEqual(analysis.existing.count, 1)
        XCTAssertTrue(analysis.conflicts.isEmpty)
    }
}
