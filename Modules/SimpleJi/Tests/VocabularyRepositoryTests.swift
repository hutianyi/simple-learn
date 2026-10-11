import CoreData
import XCTest
@testable import WordMemoryCards

final class VocabularyRepositoryTests: XCTestCase {
    @MainActor
    func testImportsAfterDailyCompletionStayOutOfTodayAndBecomeDueTomorrow() async throws {
        let calendar = DictationEligibility.calendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 23, minute: 59))!
        let tomorrow = DictationEligibility.nextDay(after: morning, calendar: calendar)
        let persistence = PersistenceController(inMemory: true)
        let vocabulary = VocabularyRepository(container: persistence.container, calendar: calendar)
        let review = ReviewRepository(container: persistence.container, calendar: calendar)
        let completion = StudyRepairRepository(container: persistence.container, calendar: calendar)
        _ = try await vocabulary.importAdditions(VocabularyParser.parse("apple 苹果").entries, now: morning)
        let originalCards = try await review.dueStates(today: morning)
        let session = try await review.startSession(mode: .scheduled, baseTaskCount: originalCards.count, startedAt: morning)
        for card in originalCards {
            _ = try await review.recordAnswer(stateID: card.id, sessionID: session, mode: .scheduled,
                answer: .known, isSameSessionRetry: false, reviewedAt: morning)
        }
        try await review.finishSession(id: session, completed: true, finishedAt: morning)
        let dictation = DictationRepository(container: persistence.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [try XCTUnwrap(originalCards.first).wordID],
            activatedAt: morning)
        let dictationDay = try await dictation.loadOrCreateDay(limit: 20, campaign: campaign, now: morning)
        _ = try await dictation.submitFormal(dayID: dictationDay.id, wordID: campaign.selectedWordIDs[0],
            recognized: "apple", now: morning)
        let finished = try await completion.today(now: morning)
        XCTAssertTrue(finished.isComplete)

        _ = try await vocabulary.importAdditions(VocabularyParser.parse("banana 香蕉\npear 梨").entries, now: evening)
        _ = try await vocabulary.importAdditions(VocabularyParser.parse("orange 橙子").entries, now: evening)
        let stillFinished = try await completion.today(now: evening)
        XCTAssertTrue(stillFinished.isComplete)
        XCTAssertEqual(stillFinished.requiredCardIDs, finished.requiredCardIDs)
        XCTAssertEqual(stillFinished.completedAt, finished.completedAt)
        XCTAssertEqual(StudyStreak.count(completedDays: [stillFinished], now: evening, calendar: calendar), 1)
        let dueToday = try await review.dueStates(today: evening)
        XCTAssertFalse(dueToday.contains { $0.english != "apple" })

        let dueTomorrow = try await review.dueStates(today: tomorrow)
        let newCards = dueTomorrow.filter { $0.english != "apple" }
        XCTAssertEqual(newCards.count, 6)
        XCTAssertEqual(Set(newCards.map(\.english)), ["banana", "pear", "orange"])
        XCTAssertTrue(newCards.allSatisfy { $0.nextReviewDate == tomorrow })
        let nextDay = try await completion.today(now: tomorrow)
        XCTAssertFalse(nextDay.isComplete)
        XCTAssertTrue(Set(newCards.map(\.id)).isSubset(of: nextDay.requiredCardIDs))
        let states = try persistence.container.viewContext.fetch(ReviewStateEntity.fetchRequest())
        for state in states where newCards.contains(where: { $0.id == state.id }) {
            XCTAssertEqual(try SRSScheduler.decodeCard(XCTUnwrap(state.fsrsCardData)).due, tomorrow)
        }
    }

    @MainActor
    func testImportBeforeDailyCompletionStillAddsTodayTasks() async throws {
        let calendar = DictationEligibility.calendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
        let persistence = PersistenceController(inMemory: true)
        let vocabulary = VocabularyRepository(container: persistence.container, calendar: calendar)
        let review = ReviewRepository(container: persistence.container, calendar: calendar)
        _ = try await vocabulary.importAdditions(VocabularyParser.parse("apple 苹果").entries, now: now)
        let cards = try await review.dueStates(today: now)
        XCTAssertEqual(cards.count, 2)
        let session = try await review.startSession(mode: .scheduled, baseTaskCount: 2, startedAt: now)
        _ = try await review.recordAnswer(stateID: cards[0].id, sessionID: session, mode: .scheduled,
            answer: .known, isSameSessionRetry: false, reviewedAt: now)
        _ = try await vocabulary.importAdditions(VocabularyParser.parse("banana 香蕉").entries, now: now)
        let due = try await review.dueStates(today: now)
        XCTAssertEqual(due.filter { $0.english == "banana" }.count, 2)
        let day = try await StudyRepairRepository(container: persistence.container, calendar: calendar).today(now: now)
        XCTAssertFalse(day.isComplete)
        XCTAssertEqual(day.requiredCardIDs.count, 4)
    }

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
