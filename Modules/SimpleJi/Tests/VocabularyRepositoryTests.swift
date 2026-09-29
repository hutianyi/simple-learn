import CoreData
import XCTest
@testable import WordMemoryCards

final class VocabularyRepositoryTests: XCTestCase {
    @MainActor
    func testNewestBatchFirstAndInputOrderWithinEachBatch() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = VocabularyRepository(container: persistence.container)
        let first = try await repository.analyze(VocabularyParser.parse("zebra 斑马\napple 苹果"))
        _ = try await repository.importAdditions(first.additions, now: Date(timeIntervalSince1970: 1000))
        let second = try await repository.analyze(VocabularyParser.parse("yellow 黄色\napple 苹果\nbanana 香蕉"))
        _ = try await repository.importAdditions(second.additions, now: Date(timeIntervalSince1970: 2000))
        let request = WordEntity.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \WordEntity.createdAt, ascending: false),
            NSSortDescriptor(keyPath: \WordEntity.importPosition, ascending: true),
            NSSortDescriptor(keyPath: \WordEntity.normalizedEnglish, ascending: true)
        ]
        let words = try persistence.container.viewContext.fetch(request)
        XCTAssertEqual(words.map(\.english), ["yellow", "banana", "zebra", "apple"])
        XCTAssertEqual(words.map(\.importPosition), [0, 1, 0, 1])
    }

    @MainActor
    func testImportCreatesOneWordAndTwoReviewStatesWithoutResettingOnRepeat() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = VocabularyRepository(container: persistence.container)
        let parseResult = VocabularyParser.parse("apple 苹果")
        let firstAnalysis = try await repository.analyze(parseResult)

        let first = try await repository.importAdditions(firstAnalysis.additions)
        XCTAssertEqual(first.insertedWords, 1)
        XCTAssertEqual(first.createdReviewStates, 2)

        let secondAnalysis = try await repository.analyze(parseResult)
        XCTAssertTrue(secondAnalysis.additions.isEmpty)
        XCTAssertEqual(secondAnalysis.existing.count, 1)

        let context = persistence.container.viewContext
        let words = try context.fetch(WordEntity.fetchRequest())
        let states = try context.fetch(ReviewStateEntity.fetchRequest())
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(states.count, 2)
    }
}
