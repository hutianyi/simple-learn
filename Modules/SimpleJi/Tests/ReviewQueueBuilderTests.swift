import XCTest
@testable import WordMemoryCards

final class ReviewQueueBuilderTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_788_192_000)

    func testOnlyDueCardsEnterAndLimitIsRespected() {
        let due = (0..<5).map { state("word\($0)", dueOffset: -$0) }
        let future = state("future", dueOffset: 10)

        let queue = ReviewQueueBuilder.buildBaseQueue(
            from: due + [future],
            sessionLimit: 3,
            today: today
        )

        XCTAssertEqual(queue.count, 3)
        XCTAssertFalse(queue.contains { $0.state.english == "future" })
    }

    func testUnlimitedQueueIncludesAll150DueCards() {
        let due = (0..<150).map { state("word\($0)", dueOffset: -1) }
        let queue = ReviewQueueBuilder.buildBaseQueue(
            from: due + [state("future", dueOffset: 10)],
            sessionLimit: nil,
            today: today
        )

        XCTAssertEqual(queue.count, 150)
        XCTAssertEqual(Set(queue.map { $0.state.id }), Set(due.map(\.id)))
    }

    @MainActor
    func testScheduledSessionIgnoresLegacyThirtyCardLimit() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = VocabularyRepository(container: persistence.container)
        let words = (0..<80).map { "word\($0) 释义" }.joined(separator: "\n")
        let analysis = try await repository.analyze(VocabularyParser.parse(words))
        _ = try await repository.importAdditions(analysis.additions)
        let session = ReviewSessionViewModel(
            container: persistence.container,
            mode: .scheduled,
            sessionLimit: 30
        )

        await session.start()
        XCTAssertEqual(session.baseTaskCount, 160)
        for _ in 0..<160 {
            session.reveal()
            await session.answer(.known)
        }
        guard case .summary(let summary) = session.phase else {
            return XCTFail("All cards should finish in one session")
        }
        XCTAssertEqual(summary.answered, 160)
        XCTAssertEqual(summary.remainingDue, 0)
    }

    func testMoreOverdueComesFirst() {
        let queue = ReviewQueueBuilder.buildBaseQueue(
            from: [state("today", dueOffset: 0), state("late", dueOffset: -8)],
            sessionLimit: nil,
            today: today
        )
        XCTAssertEqual(queue.first?.state.english, "late")
    }

    func testOppositeDirectionsAreSeparatedWhenOtherCardsExist() {
        let sharedWordID = UUID()
        var states = [
            state("apple", wordID: sharedWordID, direction: .englishToChinese),
            state("apple", wordID: sharedWordID, direction: .chineseToEnglish),
        ]
        states += (0..<7).map { state("other\($0)") }

        let queue = ReviewQueueBuilder.buildBaseQueue(from: states, sessionLimit: nil, today: today)
        let indexes = queue.enumerated().compactMap { $0.element.wordID == sharedWordID ? $0.offset : nil }

        XCTAssertEqual(indexes.count, 2)
        XCTAssertGreaterThanOrEqual(indexes[1] - indexes[0] - 1, 5)
    }

    func testOppositeDirectionIsDeferredWhenItWouldBeAdjacent() {
        let sharedWordID = UUID()
        let queue = ReviewQueueBuilder.buildBaseQueue(
            from: [
                state("apple", wordID: sharedWordID, direction: .englishToChinese),
                state("apple", wordID: sharedWordID, direction: .chineseToEnglish),
            ],
            sessionLimit: nil,
            today: today
        )
        XCTAssertEqual(queue.count, 1)
    }

    func testRetryInsertionPreservesBaseRelativeOrder() {
        let answered = ReviewTask(state: state("missed"))
        let remaining = (0..<12).map { ReviewTask(state: state("base\($0)")) }
        let updated = ReviewQueueBuilder.insertingRetry(
            for: answered,
            attempt: 1,
            into: remaining
        )

        XCTAssertEqual(updated.filter { !$0.isRetry }.map(\.state.english), remaining.map(\.state.english))
        XCTAssertEqual(updated.firstIndex(where: \.isRetry), 5)
    }

    func testThirdRetryIsNotInserted() {
        let answered = ReviewTask(state: state("missed"))
        let remaining = [ReviewTask(state: state("other"))]
        XCTAssertEqual(
            ReviewQueueBuilder.insertingRetry(for: answered, attempt: 3, into: remaining),
            remaining
        )
    }

    private func state(
        _ english: String,
        wordID: UUID = UUID(),
        direction: ReviewDirection = .englishToChinese,
        dueOffset: Int = 0
    ) -> ReviewStateSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: dueOffset, to: today)!
        return ReviewStateSnapshot(
            id: UUID(),
            wordID: wordID,
            english: english,
            normalizedEnglish: english,
            chinese: "释义",
            direction: direction,
            level: 0,
            nextReviewDate: date,
            formalKnownCount: 0,
            formalUnknownCount: 0,
            consecutiveKnown: 0,
            lastFormalResult: nil
        )
    }
}
