import CoreData
import Foundation
import XCTest
@testable import WordMemoryCards

@MainActor
final class StudyStreakTests: XCTestCase {
    private let calendar = DictationEligibility.calendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func completed(_ day: Int) -> StudyCompletionDay {
        var result = StudyCompletionDay(dayKey: "2026-10-\(String(format: "%02d", day))",
                                        timeZoneID: calendar.timeZone.identifier)
        result.hasActivity = true
        result.dictationComplete = true
        result.completedAt = date(day)
        return result
    }

    func testHistoricalCompletionDoesNotOverrideStrictSnapshots() {
        var incomplete = completed(2)
        incomplete.dictationComplete = false
        incomplete.completedAt = nil
        let historical: Set<String> = ["2026-10-01", "2026-10-02", "2026-10-03"]
        let keys = StudyStreak.completionKeys(completedDays: [incomplete, completed(3)],
            historicalKeys: historical, now: date(3), calendar: calendar)
        XCTAssertEqual(keys, ["2026-10-01", "2026-10-03"])
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(3)], now: date(3),
            calendar: calendar, historicalKeys: ["2026-10-01", "2026-10-02"]), 3)
    }

    func testHistoricalCardsRequireLastSessionFinishedOnSameDay() {
        let good = StudyStreak.HistoricalSession(startedAt: date(1), finishedAt: date(1, hour: 13),
            completed: true, required: 8, answered: 8)
        XCTAssertTrue(StudyStreak.historicalCardsFinished(sessions: [good], calendar: calendar))
        let partial = StudyStreak.HistoricalSession(startedAt: date(1, hour: 14), finishedAt: nil,
            completed: false, required: 2, answered: 1)
        XCTAssertFalse(StudyStreak.historicalCardsFinished(sessions: [good, partial], calendar: calendar))
        let late = StudyStreak.HistoricalSession(startedAt: date(1), finishedAt: date(2),
            completed: true, required: 8, answered: 8)
        XCTAssertFalse(StudyStreak.historicalCardsFinished(sessions: [late], calendar: calendar))
    }

    func testHistoricalDictationCannotCountNextDayCorrections() {
        var item = DictationItem(wordID: UUID(), english: "apple", chinese: "苹果")
        item.formalResult = false
        item.formalSubmittedAt = date(1)
        item.remediationCopyCount = 3
        item.retestAttempted = true
        item.remediationPassed = true
        XCTAssertFalse(StudyStreak.historicalDictationFinished(dayKey: "2026-10-01", phase: "complete",
            items: [item], successfulRetests: [item.wordID: [date(2)]], calendar: calendar))
        XCTAssertTrue(StudyStreak.historicalDictationFinished(dayKey: "2026-10-01", phase: "complete",
            items: [item], successfulRetests: [item.wordID: [date(1, hour: 13)]], calendar: calendar))
        XCTAssertTrue(StudyStreak.historicalDictationFinished(dayKey: "2026-10-01", phase: "complete",
            items: [], successfulRetests: [:], calendar: calendar))
    }

    func testHeatmapCovers365DaysWithMondayRowsAndFuturePadding() {
        let weeks = StudyStreak.heatmapWeeks(now: date(2), calendar: calendar)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 && calendar.component(.weekday, from: $0[0]) == 2 })
        let first = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: date(2)))!
        let visible = weeks.flatMap { $0 }.filter { $0 >= first && $0 <= calendar.startOfDay(for: date(2)) }
        XCTAssertEqual(visible.count, 365)
        XCTAssertEqual(Set(visible).count, 365)
        XCTAssertEqual(visible.last, calendar.startOfDay(for: date(2)))
    }

    func testIncompleteTodayKeepsYesterdayAndOnlyFullCompletionAddsToday() {
        let history = (1...5).map(completed)
        var today = completed(6)
        today.requiredCardIDs = [UUID()]
        today.completedAt = nil
        XCTAssertEqual(StudyStreak.count(completedDays: history + [today], now: date(6), calendar: calendar), 5)
        today.answeredCardIDs = today.requiredCardIDs
        today.completedAt = date(6)
        XCTAssertEqual(StudyStreak.count(completedDays: history + [today], now: date(6), calendar: calendar), 6)
    }

    func testIncompleteYesterdayBreaksStreakAndTodayStartsNewOne() {
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), completed(2)], now: date(4), calendar: calendar), 0)
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), completed(2), completed(4)], now: date(4), calendar: calendar), 1)
    }

    func testNoTasksAndNoActivityCannotCompleteADay() {
        var day = completed(1)
        day.hasActivity = false
        XCTAssertFalse(day.isComplete)
        XCTAssertEqual(StudyStreak.count(completedDays: [day], now: date(1), calendar: calendar), 0)
    }

    func testDictationRequiresFirstPassCopiesAndSuccessfulRetest() {
        var item = DictationItem(wordID: UUID(), english: "apple", chinese: "苹果")
        XCTAssertFalse(StudyStreak.dictationFinished(phase: "complete", items: [item]))
        item.formalResult = false
        XCTAssertFalse(StudyStreak.dictationFinished(phase: "complete", items: [item]))
        item.remediationCopyCount = 3
        XCTAssertFalse(StudyStreak.dictationFinished(phase: "retest", items: [item]))
        item.retestAttempted = true
        XCTAssertFalse(StudyStreak.dictationFinished(phase: "complete", items: [item]))
        item.remediationPassed = true
        XCTAssertTrue(StudyStreak.dictationFinished(phase: "complete", items: [item]))
        item.pendingHandwriting = "unconfirmed"
        XCTAssertFalse(StudyStreak.dictationFinished(phase: "complete", items: [item]))
        XCTAssertTrue(StudyStreak.dictationFinished(phase: "complete", items: []))
    }

    func testAllDueCardsMustBeAnsweredAndExtraPracticeDoesNotReplaceThem() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let (_, cards) = try seedWord(in: context, due: date(1), now: date(1))
        let completion = StudyCompletionRepository(container: controller.container, calendar: calendar)
        let scope = StudyCompletionScope(baselineWordIDs: [])
        try await completion.refresh(scope: scope, now: date(1))
        let review = ReviewRepository(container: controller.container, calendar: calendar)
        let extra = try await review.startSession(mode: .extraPractice, baseTaskCount: 2, startedAt: date(1))
        for card in cards {
            _ = try await review.recordAnswer(stateID: card.id, sessionID: extra, mode: .extraPractice,
                answer: .known, isSameSessionRetry: false, reviewedAt: date(1))
        }
        XCTAssertFalse(try snapshot(controller, day: 1).isComplete)
        let session = try await review.startSession(mode: .scheduled, baseTaskCount: 1, startedAt: date(1))
        _ = try await review.recordAnswer(stateID: cards[0].id, sessionID: session, mode: .scheduled,
            answer: .known, isSameSessionRetry: false, reviewedAt: date(1))
        try await review.finishSession(id: session, completed: true)
        XCTAssertFalse(try snapshot(controller, day: 1).isComplete, "One finished session can still leave a due card")
        _ = try await review.recordAnswer(stateID: cards[1].id, sessionID: session, mode: .scheduled,
            answer: .unknown, isSameSessionRetry: false, reviewedAt: date(1))
        let finished = try snapshot(controller, day: 1)
        XCTAssertEqual(finished.requiredCardIDs, Set(cards.map(\.id)))
        XCTAssertTrue(finished.isComplete, "No dictation assignments is a satisfied requirement")
    }

    func testFullDictationAndRemediationCompleteDayWithoutDueCards() async throws {
        let (controller, repository, day, id, scope) = try await dictationFixture()
        _ = try await repository.submitFormal(dayID: day.id, wordID: id, recognized: "wrong", now: date(1))
        XCTAssertFalse(try snapshot(controller, day: 1).isComplete)
        _ = try await repository.beginRemediation(dayID: day.id, now: date(1))
        for _ in 0..<3 {
            _ = try await repository.recordRemediationCopy(dayID: day.id, wordID: id,
                recognized: "apple", now: date(1))
        }
        XCTAssertFalse(try snapshot(controller, day: 1).isComplete)
        _ = try await repository.submitRetest(dayID: day.id, wordID: id, recognized: "apple", now: date(1))
        let completion = StudyCompletionRepository(container: controller.container, calendar: calendar)
        try await completion.refresh(scope: scope, now: date(1))
        XCTAssertTrue(try snapshot(controller, day: 1).isComplete)
        let settings = BackupSettings(sessionLimit: 30, englishVoiceIdentifier: nil, chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46, chineseSpeechRate: 0.46, autoSpeakFront: true, autoSpeakBack: true,
            hapticsEnabled: true, extraPracticeScope: "weakest20")
        let envelope = try await BackupService.makeEnvelope(container: controller.container,
            settings: settings, appVersion: "test")
        let restored = PersistenceController(inMemory: true)
        try await BackupService.restore(BackupService.decodeAndValidate(BackupService.encode(envelope)), into: restored.container)
        XCTAssertEqual(try snapshot(restored, day: 1), try snapshot(controller, day: 1))
        try await LearningProgressResetService.reset(container: restored.container, now: date(1), calendar: calendar)
        restored.container.viewContext.refreshAllObjects()
        XCTAssertEqual(try restored.container.viewContext.count(for: StudyCompletionDayEntity.fetchRequest()), 0)
    }

    func testTomorrowRetestCannotRetroactivelyCompleteYesterday() async throws {
        let (controller, repository, day, id, _) = try await dictationFixture()
        _ = try await repository.submitFormal(dayID: day.id, wordID: id, recognized: "wrong", now: date(1))
        _ = try await repository.beginRemediation(dayID: day.id, now: date(1))
        for _ in 0..<3 {
            _ = try await repository.recordRemediationCopy(dayID: day.id, wordID: id,
                recognized: "apple", now: date(1))
        }
        _ = try await repository.submitRetest(dayID: day.id, wordID: id, recognized: "apple", now: date(2))
        XCTAssertFalse(try snapshot(controller, day: 1).isComplete)
        XCTAssertNil(try snapshot(controller, day: 1).completedAt)
    }

    func testRaisingDailyDictationLimitRevokesCompletionUntilNewWordsFinished() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let (first, _) = try seedWord(in: context, due: date(10), now: date(1))
        let (second, _) = try seedWord(in: context, due: date(10), now: date(1), english: "pear")
        for word in [first, second] {
            let state = DictationStateEntity(context: context)
            state.id = UUID(); state.wordID = word.id; state.word = word
            state.englishVersion = word.english; state.initialCopyCount = 3
            state.initialCopyStartedAt = date(1); state.initialCopyCompletedAt = date(1)
            state.totalFormal = 1; state.nextReviewDate = date(1)
        }
        try context.save()
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(1))
        let day = try await repository.loadOrCreateDay(limit: 1, campaign: campaign, now: date(1))
        _ = try await repository.submitFormal(dayID: day.id, wordID: day.items[0].wordID,
            recognized: day.items[0].english, now: date(1))
        XCTAssertTrue(try snapshot(controller, day: 1).isComplete)
        let expanded = try await repository.loadOrCreateDay(limit: 2, campaign: campaign, now: date(1))
        XCTAssertFalse(try snapshot(controller, day: 1).isComplete)
        let pending = try XCTUnwrap(expanded.items.first { $0.formalResult == nil })
        _ = try await repository.submitFormal(dayID: day.id, wordID: pending.wordID, recognized: pending.english, now: date(1))
        XCTAssertTrue(try snapshot(controller, day: 1).isComplete)
    }

    private func snapshot(_ controller: PersistenceController, day: Int) throws -> StudyCompletionDay {
        let context = controller.container.viewContext
        context.refreshAllObjects()
        let key = DictationEligibility.dayKey(for: date(day), calendar: calendar)
        let entity = try XCTUnwrap(try context.fetch(StudyCompletionDayEntity.fetchRequest()).first { $0.dayKey == key })
        return try JSONDecoder().decode(StudyCompletionDay.self, from: entity.snapshotData)
    }

    private func dictationFixture() async throws
        -> (PersistenceController, DictationRepository, DictationDay, UUID, StudyCompletionScope) {
        let controller = PersistenceController(inMemory: true)
        let (word, _) = try seedWord(in: controller.container.viewContext, due: date(10), now: date(1))
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [word.id], activatedAt: date(1))
        let day = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(1))
        return (controller, repository, day, word.id, StudyCompletionScope(baselineWordIDs: [word.id]))
    }

    private func seedWord(in context: NSManagedObjectContext, due: Date, now: Date, english: String = "apple") throws
        -> (WordEntity, [ReviewStateEntity]) {
        let word = WordEntity(context: context)
        word.id = UUID(); word.english = english; word.normalizedEnglish = english; word.chinese = "测试"
        word.createdAt = now; word.updatedAt = now
        let cards = ReviewDirection.allCases.map { direction -> ReviewStateEntity in
            let state = ReviewStateEntity(context: context)
            state.id = UUID(); state.word = word; state.direction = direction.rawValue
            state.createdAt = now; state.updatedAt = now; state.nextReviewDate = due
            return state
        }
        try context.save()
        return (word, cards)
    }
}
