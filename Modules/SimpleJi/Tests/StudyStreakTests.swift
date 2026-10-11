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

    func testCelebrationRequiresStrictCurrentDayCompletionAndOnlyRunsOnce() {
        var day = completed(2)
        XCTAssertTrue(StudyStreak.shouldCelebrate(day: day, todayKey: "2026-10-02", lastCelebratedKey: "2026-10-01"))
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: day, todayKey: "2026-10-02", lastCelebratedKey: "2026-10-02"))
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: day, todayKey: "2026-10-03", lastCelebratedKey: ""))
        day.dictationComplete = false
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: day, todayKey: "2026-10-02", lastCelebratedKey: ""))
        day.dictationComplete = true
        day.requiredCardIDs = [UUID()]
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: day, todayKey: "2026-10-02", lastCelebratedKey: ""))
        day.answeredCardIDs = day.requiredCardIDs
        day.completedAt = nil
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: day, todayKey: "2026-10-02", lastCelebratedKey: ""))
        day.completedAt = date(2)
        day.hasActivity = false
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: day, todayKey: "2026-10-02", lastCelebratedKey: ""))
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


    func testRepairBlocksCelebrationUntilNormalAndExtraTasksFinish() {
        var today = completed(3)
        today.repair = StudyRepairPlan(yesterdayKey: "2026-10-02", previousStreak: 1,
            extraCardIDs: [UUID()], cardsComplete: false, dictationComplete: true, status: .accepted)
        today.completedAt = nil
        XCTAssertFalse(today.isComplete)
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: today, todayKey: today.dayKey, lastCelebratedKey: ""))
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), today], now: date(3), calendar: calendar), 0)
        today.repair?.cardsComplete = true
        today.repair?.status = .completed
        today.repair?.restoredAt = date(3)
        today.completedAt = date(3)
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), today], now: date(3), calendar: calendar), 3)
        XCTAssertTrue(StudyStreak.shouldCelebrate(day: today, todayKey: today.dayKey, lastCelebratedKey: ""))
        XCTAssertEqual(StudyStreak.repairedKeys(completedDays: [today], now: date(3)), ["2026-10-02"])
        today.repair?.status = .abandoned
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), today], now: date(3), calendar: calendar), 1)
    }

    func testRepairDeclineAndReentryConsumeOnlyThisOpportunity() async throws {
        let (controller, repository, offer) = try await repairFixture()
        try await repository.decide(offer, accepted: false, now: date(3))
        let afterDecline = try await repository.prepare(now: date(3))
        XCTAssertNil(afterDecline)
        XCTAssertEqual(try snapshot(controller, day: 3).repair?.status, .declined)
        let (second, secondRepository, secondOffer) = try await repairFixture()
        try await secondRepository.decide(secondOffer, accepted: true, now: date(3))
        let afterReentry = try await secondRepository.prepare(now: date(3))
        XCTAssertNil(afterReentry)
        XCTAssertEqual(try snapshot(second, day: 3).repair?.status, .abandoned)
        let tomorrowOffer = try await secondRepository.prepare(now: date(4))
        XCTAssertNil(tomorrowOffer)
    }

    func testRepairCreditsOverdueCardsInsteadOfDuplicatingTheirQuantity() async throws {
        let (controller, repository, offer) = try await repairFixture(overdue: true)
        XCTAssertTrue(offer.plan.extraCardIDs.isEmpty)
        XCTAssertEqual(offer.normalCardCount, 2)
        try await repository.decide(offer, accepted: true, now: date(3))
        let context = controller.container.viewContext
        let cards = try context.fetch(ReviewStateEntity.fetchRequest())
        let review = ReviewRepository(container: controller.container, calendar: calendar)
        let session = try await review.startSession(mode: .scheduled, baseTaskCount: cards.count, startedAt: date(3))
        for card in cards {
            _ = try await review.recordAnswer(stateID: card.id, sessionID: session, mode: .scheduled,
                answer: .known, isSameSessionRetry: false, reviewedAt: date(3))
        }
        let day = try await repository.today(now: date(3))
        XCTAssertEqual(day.repair?.status, .completed)
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), day], now: date(3), calendar: calendar), 3)
    }

    func testRepairDictationReusesCorrectionsWithoutChangingFormalSchedule() async throws {
        let (controller, _, _) = try await repairFixture()
        let context = controller.container.viewContext
        let word = try XCTUnwrap(try context.fetch(WordEntity.fetchRequest()).first)
        let state = DictationStateEntity(context: context)
        state.id = UUID(); state.wordID = word.id; state.word = word
        state.englishVersion = word.english; state.initialCopyCount = 3
        state.initialCopyStartedAt = date(1); state.initialCopyCompletedAt = date(1)
        state.totalFormal = 1; state.nextReviewDate = date(10); state.lastFormalDay = "2026-10-03"
        let entity = DictationDayEntity(context: context)
        entity.id = UUID(); entity.dayKey = "2026-10-03#repair"
        entity.timeZoneID = calendar.timeZone.identifier; entity.limit = 0
        entity.phase = DictationPhase.firstPass.rawValue
        entity.tasksData = try JSONEncoder().encode([DictationItem(wordID: word.id, english: word.english, chinese: word.chinese)])
        entity.createdAt = date(3); entity.updatedAt = date(3)
        let id = entity.id; let wordID = word.id
        try context.save()
        let repo = DictationRepository(container: controller.container, calendar: calendar)
        _ = try await repo.submitFormal(dayID: id, wordID: wordID, recognized: "wrong", now: date(3))
        _ = try await repo.beginRemediation(dayID: id, now: date(3))
        for _ in 0..<3 {
            _ = try await repo.recordRemediationCopy(dayID: id, wordID: wordID, recognized: "apple", now: date(3))
        }
        _ = try await repo.submitRetest(dayID: id, wordID: wordID, recognized: "apple", now: date(3))
        context.refreshAllObjects()
        XCTAssertEqual(state.totalFormal, 1)
        XCTAssertEqual(state.nextReviewDate, date(10))
        XCTAssertNil(state.formalNotBefore)
        XCTAssertEqual(state.lastFormalDay, "2026-10-03")
        let events = try context.fetch(DictationEventEntity.fetchRequest())
        XCTAssertEqual(events.first { $0.kind == "repairFormal" }?.submittedAt, date(3))
        XCTAssertNil(events.first { $0.kind == "repairFormal" }?.formalKey)
        let normal = try await repo.loadOrCreateDay(limit: 20,
            campaign: BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(1)), now: date(3))
        XCTAssertFalse(normal.isStreakRepair)
        do { _ = try await repo.repairDay(id: id, now: date(4)); XCTFail("Expired repair loaded") }
        catch { }
    }

    func testFullRepairRoundTripRestoresYesterdayOnlyAfterAllWorkIsSaved() async throws {
        let (controller, repository, _) = try await repairFixture()
        let context = controller.container.viewContext
        let word = try XCTUnwrap(try context.fetch(WordEntity.fetchRequest()).first)
        let state = DictationStateEntity(context: context)
        state.id = UUID(); state.wordID = word.id; state.word = word
        state.englishVersion = word.english; state.initialCopyCount = 3
        state.initialCopyStartedAt = date(1); state.initialCopyCompletedAt = date(1)
        state.totalFormal = 1; state.nextReviewDate = date(2)
        var item = DictationItem(wordID: word.id, english: word.english, chinese: word.chinese)
        item.formalResult = true; item.formalSubmittedAt = date(1)
        let reference = DictationDayEntity(context: context)
        reference.id = UUID(); reference.dayKey = "2026-10-01"; reference.timeZoneID = calendar.timeZone.identifier
        reference.limit = 20; reference.phase = DictationPhase.complete.rawValue
        reference.tasksData = try JSONEncoder().encode([item]); reference.createdAt = date(1); reference.updatedAt = date(1)
        try context.save()
        let prepared = try await repository.prepare(now: date(3))
        let offer = try XCTUnwrap(prepared)
        XCTAssertTrue(offer.plan.extraCardIDs.isEmpty)
        XCTAssertNil(offer.plan.dictationDayID)
        try await repository.decide(offer, accepted: true, now: date(3))
        let review = ReviewRepository(container: controller.container, calendar: calendar)
        let cards = try await review.dueStates(today: date(3))
        let session = try await review.startSession(mode: .scheduled, baseTaskCount: cards.count, startedAt: date(3))
        for card in cards {
            _ = try await review.recordAnswer(stateID: card.id, sessionID: session, mode: .scheduled,
                answer: .known, isSameSessionRetry: false, reviewedAt: date(3))
        }
        try await review.finishSession(id: session, completed: true, finishedAt: date(3))
        let before = try await repository.today(now: date(3))
        XCTAssertFalse(before.isComplete)
        XCTAssertEqual(before.repair?.status, .accepted)
        let dictation = DictationRepository(container: controller.container, calendar: calendar)
        let normal = try await dictation.loadOrCreateDay(limit: 20,
            campaign: BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(1)), now: date(3))
        XCTAssertEqual(normal.items.map(\.wordID), [word.id])
        _ = try await dictation.submitFormal(dayID: normal.id, wordID: word.id, recognized: "apple", now: date(3))
        let after = try await repository.today(now: date(3))
        XCTAssertEqual(after.repair?.status, .completed)
        XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), after], now: date(3), calendar: calendar), 3)
        let settings = BackupSettings(sessionLimit: 30, englishVoiceIdentifier: nil, chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46, chineseSpeechRate: 0.46, autoSpeakFront: true, autoSpeakBack: true,
            hapticsEnabled: true, extraPracticeScope: "weakest20")
        let envelope = try await BackupService.makeEnvelope(container: controller.container, settings: settings, appVersion: "test")
        let decoded = try BackupService.decodeAndValidate(BackupService.encode(envelope))
        let restored = PersistenceController(inMemory: true)
        try await BackupService.restore(decoded, into: restored.container)
        XCTAssertEqual(try snapshot(restored, day: 3).repair, after.repair)
        XCTAssertEqual(StudyStreak.repairedKeys(completedDays: decoded.data.completionDays ?? [], now: date(3)), ["2026-10-02"])
        XCTAssertFalse(decoded.data.reviewEvents.contains { $0.reviewedAt == date(2) })
        XCTAssertFalse((decoded.data.dictationEvents ?? []).contains { $0.submittedAt == date(2) })
    }

    func testRepairChoiceDoesNotChangeNormalQueuesOrDictationLimit() async throws {
        for accepted in [false, true] {
            let (controller, repository, _) = try await repairFixture(overdue: true)
            let context = controller.container.viewContext
            for index in 0..<12 {
                let (word, _) = try seedWord(in: context, due: date(2), now: date(1), english: "word\(index)")
                let state = DictationStateEntity(context: context)
                state.id = UUID(); state.wordID = word.id; state.word = word
                state.englishVersion = word.english; state.totalFormal = 1
                state.initialCopyStartedAt = date(1); state.initialCopyCompletedAt = date(1)
                state.initialCopyCount = 3
                state.nextReviewDate = date(2)
            }
            try context.save()
            let review = ReviewRepository(container: controller.container, calendar: calendar)
            let cardsBefore = try await review.dueStates(today: date(3))
            XCTAssertEqual(cardsBefore.count, 26)
            let dictation = DictationRepository(container: controller.container, calendar: calendar)
            let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(1))
            let queueBefore = try await dictation.loadOrCreateDay(limit: 10, campaign: campaign, now: date(3))
            let prepared = try await repository.prepare(now: date(3))
            let offer = try XCTUnwrap(prepared)
            XCTAssertTrue(offer.plan.extraCardIDs.isEmpty)
            try await repository.decide(offer, accepted: accepted, now: date(3))
            let cardsAfter = try await review.dueStates(today: date(3))
            let queueAfter = try await dictation.loadOrCreateDay(limit: 10, campaign: campaign, now: date(3))
            XCTAssertEqual(Set(cardsBefore.map(\.id)), Set(cardsAfter.map(\.id)))
            XCTAssertEqual(queueBefore, queueAfter)
            XCTAssertEqual(queueAfter.items.count, 10)
            let exhaustedBefore = try await repository.dictationAllowanceExhausted(now: date(3))
            XCTAssertFalse(exhaustedBefore)
            XCTAssertNil(try snapshot(controller, day: 3).repair?.dictationDayID)
            XCTAssertFalse(try context.fetch(DictationDayEntity.fetchRequest()).contains { $0.dayKey.hasSuffix("#repair") })
            let untouched = Set(try context.fetch(DictationStateEntity.fetchRequest()).map(\.wordID))
                .subtracting(queueAfter.items.map(\.wordID))
            XCTAssertEqual(untouched.count, 2)
            let session = try await review.startSession(mode: .scheduled, baseTaskCount: cardsAfter.count, startedAt: date(3))
            for card in cardsAfter {
                _ = try await review.recordAnswer(stateID: card.id, sessionID: session, mode: .scheduled,
                    answer: .known, isSameSessionRetry: false, reviewedAt: date(3))
            }
            for item in queueAfter.items {
                _ = try await dictation.submitFormal(dayID: queueAfter.id, wordID: item.wordID,
                    recognized: item.english, now: date(3))
            }
            let finished = try await repository.today(now: date(3))
            XCTAssertFalse(finished.isComplete, "Two previous days' words remain outside today's allowance")
            XCTAssertEqual(finished.repair?.status, accepted ? .accepted : .declined)
            XCTAssertEqual(StudyStreak.count(completedDays: [completed(1), finished], now: date(3), calendar: calendar), 0)
            let exhaustedAfter = try await repository.dictationAllowanceExhausted(now: date(3))
            XCTAssertTrue(exhaustedAfter, "The repair flow must stop rather than reopen the completed queue")
            let next = try await dictation.loadOrCreateDay(limit: 10, campaign: campaign, now: date(4))
            XCTAssertLessThanOrEqual(next.items.count, 10)
            XCTAssertEqual(Set(next.items.prefix(2).map(\.wordID)), untouched)
        }
    }

    func testBaselineHonorsDailyLimitPreservesProgressAndDefersRemainingWords() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        var ids: [UUID] = []
        for index in 0..<12 {
            let (word, _) = try seedWord(in: context, due: date(10), now: date(1), english: "old\(index)")
            ids.append(word.id)
        }
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: ids, activatedAt: date(1))
        let repo = DictationRepository(container: controller.container, calendar: calendar)
        let initial = try await repo.loadOrCreateDay(limit: 10, campaign: campaign, now: date(3))
        XCTAssertEqual(initial.limit, 10)
        XCTAssertEqual(initial.items.count, 10)
        let first = try XCTUnwrap(initial.items.first)
        _ = try await repo.submitFormal(dayID: initial.id, wordID: first.wordID, recognized: first.english, now: date(3))
        let reduced = try await repo.loadOrCreateDay(limit: 5, campaign: campaign, now: date(3))
        XCTAssertEqual(reduced.items.count, 5)
        XCTAssertEqual(reduced.items.first?.formalResult, true)
        let expanded = try await repo.loadOrCreateDay(limit: 10, campaign: campaign, now: date(3))
        XCTAssertEqual(expanded.items.count, 10)
        XCTAssertEqual(expanded.firstPassAnswered, 1)
        for item in expanded.items where item.formalResult == nil {
            _ = try await repo.submitFormal(dayID: expanded.id, wordID: item.wordID, recognized: item.english, now: date(3))
        }
        let finished = try await repo.loadOrCreateDay(limit: 10, campaign: campaign, now: date(3))
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertEqual(finished.items.count, 10)
        let next = try await repo.loadOrCreateDay(limit: 10, campaign: campaign, now: date(4))
        XCTAssertEqual(next.items.count, 2)
        XCTAssertTrue(Set(next.items.map(\.wordID)).isDisjoint(with: expanded.items.map(\.wordID)))
        let unlimited = try await repo.loadOrCreateDay(limit: 0, campaign: campaign, now: date(4))
        XCTAssertEqual(unlimited.limit, 50)
        XCTAssertEqual(unlimited.items.count, 2)
    }

    func testOverdueDictationUsesDailyAllowanceBeforeTodaysWords() async throws {
        let (controller, repository, ids, campaign) = try limitedOverdueFixture(overdue: 30, dueToday: 30)
        let day = try await repository.loadOrCreateDay(limit: 50, campaign: campaign, now: date(3))
        XCTAssertEqual(day.items.count, 50)
        XCTAssertEqual(Set(day.items.prefix(30).map(\.wordID)), Set(ids.prefix(30)))
        XCTAssertEqual(Set(day.items.dropFirst(30).map(\.wordID)), Set(ids[30..<50]))
        for item in day.items {
            _ = try await repository.submitFormal(dayID: day.id, wordID: item.wordID, recognized: item.english, now: date(3))
        }
        let finished = try snapshot(controller, day: 3)
        XCTAssertTrue(finished.isComplete, "Today's words beyond the allowance are deferred, not previous debt")
        XCTAssertTrue(StudyStreak.shouldCelebrate(day: finished, todayKey: finished.dayKey, lastCelebratedKey: ""))
        let reopened = try await repository.loadOrCreateDay(limit: 50, campaign: campaign, now: date(3))
        XCTAssertEqual(reopened.items.count, 50)
        XCTAssertEqual(reopened.phase, .complete)
        let next = try await repository.loadOrCreateDay(limit: 50, campaign: campaign, now: date(4))
        XCTAssertEqual(Set(next.items.prefix(10).map(\.wordID)), Set(ids[50...]), "Yesterday's ten deferred words have priority today")
        XCTAssertLessThanOrEqual(next.items.count, 50)
        controller.container.viewContext.refreshAllObjects()
        XCTAssertEqual(try controller.container.viewContext.fetch(DictationEventEntity.fetchRequest()).filter { $0.kind == "formal" }.count, 50)
    }

    func testOverdueWordsOutsideCompletedDailyAllowanceBlockCelebration() async throws {
        let (controller, repository, ids, campaign) = try limitedOverdueFixture(overdue: 6, dueToday: 1)
        let day = try await repository.loadOrCreateDay(limit: 5, campaign: campaign, now: date(3))
        XCTAssertEqual(day.items.count, 5)
        XCTAssertTrue(Set(day.items.map(\.wordID)).isSubset(of: Set(ids.prefix(6))))
        for item in day.items {
            _ = try await repository.submitFormal(dayID: day.id, wordID: item.wordID, recognized: item.english, now: date(3))
        }
        let unfinished = try snapshot(controller, day: 3)
        XCTAssertFalse(unfinished.dictationComplete)
        XCTAssertFalse(unfinished.isComplete)
        XCTAssertNil(unfinished.completedAt)
        XCTAssertFalse(StudyStreak.shouldCelebrate(day: unfinished, todayKey: unfinished.dayKey, lastCelebratedKey: ""))
        let reopened = try await repository.loadOrCreateDay(limit: 5, campaign: campaign, now: date(3))
        XCTAssertEqual(reopened.items.count, 5, "Do not bypass the daily allowance to clear debt")
        XCTAssertEqual(reopened.phase, .complete)
        let next = try await repository.loadOrCreateDay(limit: 5, campaign: campaign, now: date(4))
        XCTAssertEqual(Set(next.items.prefix(2).map(\.wordID)), Set(ids[5...]))
        XCTAssertLessThanOrEqual(next.items.count, 5)
        for item in next.items {
            _ = try await repository.submitFormal(dayID: next.id, wordID: item.wordID, recognized: item.english, now: date(4))
        }
        XCTAssertTrue(try snapshot(controller, day: 4).isComplete)
        XCTAssertFalse(try snapshot(controller, day: 3).isComplete, "Clearing debt later must not rewrite yesterday")
    }

    func testOverdueFirstFormalWordAlsoPrecedesTodaysRegularReview() async throws {
        let (controller, repository, ids, campaign) = try limitedOverdueFixture(overdue: 1, dueToday: 1)
        let context = controller.container.viewContext
        let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest()).first { $0.wordID == ids[0] })
        state.totalFormal = 0
        try context.save()
        let day = try await repository.loadOrCreateDay(limit: 1, campaign: campaign, now: date(3))
        XCTAssertEqual(day.items.map(\.wordID), [ids[0]])
        _ = try await repository.submitFormal(dayID: day.id, wordID: ids[0], recognized: "wrong", now: date(3))
        _ = try await repository.beginRemediation(dayID: day.id, now: date(3))
        for _ in 0..<3 { _ = try await repository.recordRemediationCopy(dayID: day.id, wordID: ids[0], recognized: "word0", now: date(3)) }
        XCTAssertFalse(try snapshot(controller, day: 3).isComplete)
        _ = try await repository.submitRetest(dayID: day.id, wordID: ids[0], recognized: "wrong", now: date(3))
        XCTAssertFalse(try snapshot(controller, day: 3).isComplete)
        for _ in 0..<3 { _ = try await repository.recordRemediationCopy(dayID: day.id, wordID: ids[0], recognized: "word0", now: date(3)) }
        _ = try await repository.submitRetest(dayID: day.id, wordID: ids[0], recognized: "word0", now: date(3))
        XCTAssertTrue(try snapshot(controller, day: 3).isComplete)
    }

    private func limitedOverdueFixture(overdue: Int, dueToday: Int) throws
        -> (PersistenceController, DictationRepository, [UUID], BaselineCampaignSnapshot) {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        var ids: [UUID] = []
        for index in 0..<(overdue + dueToday) {
            let (word, _) = try seedWord(in: context, due: date(10), now: date(1), english: "word\(index)")
            let state = DictationStateEntity(context: context)
            state.id = UUID(); state.wordID = word.id; state.word = word
            state.englishVersion = word.english; state.totalFormal = 1
            state.initialCopyStartedAt = date(1); state.initialCopyCompletedAt = date(1)
            state.initialCopyCount = 3
            state.nextReviewDate = date(index < overdue ? 2 : 3).addingTimeInterval(Double(index))
            state.fsrsCardData = try SRSScheduler.encodeCard(SRSScheduler.emptyCard(due: state.nextReviewDate!))
            ids.append(word.id)
        }
        try context.save()
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(1))
        return (controller, DictationRepository(container: controller.container, calendar: calendar), ids, campaign)
    }

    private func repairFixture(overdue: Bool = false) async throws -> (PersistenceController, StudyRepairRepository, StudyRepairOffer) {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let (_, cards) = try seedWord(in: context, due: date(overdue ? 2 : 3), now: date(1))
        for card in cards {
            card.totalReviews = 1; card.knownCount = 1
            card.fsrsCardData = try SRSScheduler.encodeCard(SRSScheduler.emptyCard(due: card.nextReviewDate))
            card.fsrsMigrationVersion = SRSScheduler.migrationVersion
        }
        var past = completed(1)
        past.requiredCardIDs = Set(cards.map(\.id))
        past.answeredCardIDs = past.requiredCardIDs
        let entity = StudyCompletionDayEntity(context: context)
        entity.dayKey = past.dayKey
        entity.snapshotData = try JSONEncoder().encode(past)
        try context.save()
        try await StudyCompletionRepository(container: controller.container, calendar: calendar)
            .refresh(scope: StudyCompletionScope(baselineWordIDs: []), now: date(3))
        let repository = StudyRepairRepository(container: controller.container, calendar: calendar)
        let prepared = try await repository.prepare(now: date(3))
        let offer = try XCTUnwrap(prepared)
        return (controller, repository, offer)
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

    func testDirectNewWordNeedsNoInitialCopyAndCompletesTodayOnlyOnce() async throws {
        let controller = PersistenceController(inMemory: true)
        let word = try seedDirectWord(in: controller.container.viewContext)
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(3))
        let day = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        XCTAssertEqual(day.items.map(\.wordID), [word.id])
        XCTAssertEqual(day.items.first?.isNewWord, true)
        XCTAssertEqual(day.phase, .firstPass)
        XCTAssertFalse(try snapshot(controller, day: 3).dictationComplete)
        XCTAssertEqual(try controller.container.viewContext.count(for: DictationStateEntity.fetchRequest()), 0)
        let answer = try await repository.submitFormal(dayID: day.id, wordID: word.id,
            recognized: "apple", now: date(3))
        guard case .result(let finished, let correct, _) = answer else { return XCTFail("Expected result") }
        XCTAssertTrue(correct)
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertTrue(try snapshot(controller, day: 3).isComplete)
        let state = try XCTUnwrap(word.dictationState)
        XCTAssertEqual(state.totalFormal, 1)
        XCTAssertEqual(state.initialCopyCount, 0)
        XCTAssertNil(state.initialCopyCompletedAt)
        XCTAssertNotNil(state.nextReviewDate)
        do {
            _ = try await repository.submitFormal(dayID: day.id, wordID: word.id,
                recognized: "apple", now: date(3))
            XCTFail("Must not score the same first answer twice")
        } catch DictationRepository.DictationError.alreadyAnswered {}
        XCTAssertEqual(try controller.container.viewContext.fetch(DictationEventEntity.fetchRequest()).map(\.kind), ["formal"])
    }

    func testDirectWrongWordRequiresCopyAndRetestWithoutChangingFirstScore() async throws {
        let controller = PersistenceController(inMemory: true)
        let word = try seedDirectWord(in: controller.container.viewContext)
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let day = try await repository.loadOrCreateDay(limit: 20,
            campaign: BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(3)), now: date(3))
        _ = try await repository.submitFormal(dayID: day.id, wordID: word.id, recognized: "aple", now: date(3))
        controller.container.viewContext.refreshAllObjects()
        let state = try XCTUnwrap(word.dictationState)
        let cardAfterFirst = state.fsrsCardData
        XCTAssertFalse(try snapshot(controller, day: 3).isComplete)
        _ = try await repository.beginRemediation(dayID: day.id, now: date(3))
        for _ in 0..<3 {
            _ = try await repository.recordRemediationCopy(dayID: day.id, wordID: word.id,
                recognized: "apple", now: date(3))
        }
        XCTAssertFalse(try snapshot(controller, day: 3).isComplete)
        let result = try await repository.submitRetest(dayID: day.id, wordID: word.id,
            recognized: "apple", now: date(3))
        guard case .result(let finished, let correct, _) = result else { return XCTFail("Expected retest") }
        XCTAssertTrue(correct)
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertEqual(finished.firstPassAccuracy, 0)
        XCTAssertTrue(try snapshot(controller, day: 3).isComplete)
        XCTAssertEqual(state.totalFormal, 1)
        XCTAssertEqual(state.fsrsCardData, cardAfterFirst)
    }

    func testDirectNewWordsShareDailyAllowanceKeepFiveWordCapAndDoNotReopenCompletion() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let overdue = try seedDirectWord(in: context, english: "overdue")
        let state = DictationStateEntity(context: context)
        state.id = UUID(); state.word = overdue; state.wordID = overdue.id
        state.englishVersion = overdue.english; state.totalFormal = 1
        state.initialCopyStartedAt = date(1); state.nextReviewDate = date(2)
        state.fsrsCardData = try SRSScheduler.encodeCard(SRSScheduler.emptyCard(due: date(2)))
        let newWords = try (0..<7).map { try seedDirectWord(in: context, english: "word\($0)", position: Int64($0)) }
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(3))
        let small = try await repository.loadOrCreateDay(limit: 3, campaign: campaign, now: date(3))
        XCTAssertEqual(small.items.map(\.wordID), [overdue.id] + newWords.prefix(2).map(\.id))
        let expanded = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        XCTAssertEqual(expanded.items.count, 6)
        XCTAssertEqual(expanded.items.filter { $0.isNewWord == true }.count, 5)
        for item in expanded.items {
            _ = try await repository.submitFormal(dayID: expanded.id, wordID: item.wordID,
                recognized: item.english, now: date(3))
        }
        let completion = try snapshot(controller, day: 3)
        XCTAssertTrue(completion.isComplete, "Unscheduled new words must not block today's completion")
        let repeated = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        XCTAssertEqual(repeated.items.count, 6)
        XCTAssertEqual(repeated.phase, .complete)
        XCTAssertEqual(try snapshot(controller, day: 3).completedAt, completion.completedAt)
        let tomorrow = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(4))
        XCTAssertTrue(Set(newWords.suffix(2).map(\.id)).isSubset(of: Set(tomorrow.items.map(\.wordID))))
    }

    func testDirectDictationResumesLegacyPartialCopyWithoutInventingCopyCompletion() async throws {
        let controller = PersistenceController(inMemory: true)
        let word = try seedDirectWord(in: controller.container.viewContext)
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(3))
        _ = try await repository.initialCopyQueue(campaign: campaign, now: date(3))
        _ = try await repository.recordInitialCopy(wordID: word.id, recognized: "apple", now: date(3))
        let day = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        XCTAssertEqual(day.items.map(\.wordID), [word.id])
        XCTAssertEqual(day.items.first?.isNewWord, true)
        _ = try await repository.submitFormal(dayID: day.id, wordID: word.id, recognized: "apple", now: date(3))
        _ = try snapshot(controller, day: 3)
        XCTAssertEqual(word.dictationState?.initialCopyCount, 1)
        XCTAssertNil(word.dictationState?.initialCopyCompletedAt)
        XCTAssertEqual(word.dictationState?.totalFormal, 1)
    }

    func testDirectWordBecomingEligibleAfterEmptyPreviewBlocksPrematureCompletion() async throws {
        let controller = PersistenceController(inMemory: true)
        let (word, cards) = try seedWord(in: controller.container.viewContext, due: date(10), now: date(1))
        let review = ReviewRepository(container: controller.container, calendar: calendar)
        let card = try XCTUnwrap(cards.first { $0.direction == ReviewDirection.chineseToEnglish.rawValue })
        let first = try await review.startSession(mode: .scheduled, baseTaskCount: 1, startedAt: date(1))
        _ = try await review.recordAnswer(stateID: card.id, sessionID: first, mode: .scheduled,
            answer: .known, isSameSessionRetry: false, reviewedAt: date(1))
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(3))
        let empty = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        XCTAssertTrue(empty.items.isEmpty)
        let second = try await review.startSession(mode: .scheduled, baseTaskCount: 1, startedAt: date(3))
        _ = try await review.recordAnswer(stateID: card.id, sessionID: second, mode: .scheduled,
            answer: .known, isSameSessionRetry: false, reviewedAt: date(3))
        XCTAssertFalse(try snapshot(controller, day: 3).isComplete)
        let filled = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        XCTAssertEqual(filled.id, empty.id)
        XCTAssertEqual(filled.items.map(\.wordID), [word.id])
        _ = try await repository.submitFormal(dayID: filled.id, wordID: word.id, recognized: "apple", now: date(3))
        XCTAssertTrue(try snapshot(controller, day: 3).isComplete)
    }

    func testDirectEligibleWordsDoNotReopenAnAlreadyCompletedEmptyDayAfterUpgrade() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(3))
        let empty = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        let word = try seedDirectWord(in: context)
        try XCTUnwrap(word.events.first).reviewedAt = date(3)
        let entity = try XCTUnwrap(try context.fetch(StudyCompletionDayEntity.fetchRequest()).first)
        var prior = completed(3)
        prior.scope = StudyCompletionScope(baselineWordIDs: [])
        entity.snapshotData = try JSONEncoder().encode(prior)
        try context.save()
        let sameDay = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(3))
        XCTAssertEqual(sameDay.id, empty.id)
        XCTAssertTrue(sameDay.items.isEmpty)
        XCTAssertTrue(try snapshot(controller, day: 3).isComplete)
        let nextDay = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: date(4))
        XCTAssertTrue(nextDay.items.contains { $0.wordID == word.id })
    }

    func testDirectNewQueueSurvivesBackupAndMasteredOrUnlearnedWordsStayExcluded() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let word = try seedDirectWord(in: context)
        let mastered = try seedDirectWord(in: context, english: "mastered")
        _ = try seedWord(in: context, due: date(10), now: date(3), english: "unlearned")
        let repository = DictationRepository(container: controller.container, calendar: calendar)
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: date(3))
        let day = try await repository.loadOrCreateDay(limit: 20, campaign: campaign,
            masteredTerms: [mastered.english], now: date(3))
        XCTAssertEqual(day.items.map(\.wordID), [word.id])
        let settings = BackupSettings(sessionLimit: 30, englishVoiceIdentifier: nil, chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46, chineseSpeechRate: 0.46, autoSpeakFront: true, autoSpeakBack: true,
            hapticsEnabled: true, extraPracticeScope: "weakest20")
        let envelope = try await BackupService.makeEnvelope(container: controller.container,
            settings: settings, appVersion: "test")
        let restored = PersistenceController(inMemory: true)
        try await BackupService.restore(BackupService.decodeAndValidate(BackupService.encode(envelope)), into: restored.container)
        let restoredRepository = DictationRepository(container: restored.container, calendar: calendar)
        let resumed = try await restoredRepository.loadOrCreateDay(limit: 20, campaign: campaign,
            masteredTerms: [mastered.english], now: date(3))
        XCTAssertEqual(resumed, day)
        _ = try await restoredRepository.submitFormal(dayID: resumed.id, wordID: word.id,
            recognized: "apple", now: date(3))
        XCTAssertTrue(try snapshot(restored, day: 3).isComplete)
    }

    private func seedDirectWord(in context: NSManagedObjectContext, english: String = "apple", position: Int64 = 0) throws -> WordEntity {
        let (word, cards) = try seedWord(in: context, due: date(10), now: date(1), english: english)
        word.importPosition = position
        let card = try XCTUnwrap(cards.first { $0.direction == ReviewDirection.chineseToEnglish.rawValue })
        let session = StudySessionEntity(context: context)
        session.id = UUID(); session.mode = PracticeMode.scheduled.rawValue
        session.startedAt = date(1); session.completed = true; session.baseTaskCount = 2
        session.formalAnswered = 2; session.formalKnown = 2
        for day in [1, 2] {
            let event = ReviewEventEntity(context: context)
            event.id = UUID(); event.word = word; event.reviewState = card
            event.session = session; event.sessionID = session.id; event.reviewedAt = date(day)
            event.direction = card.direction; event.result = ReviewResult.known.rawValue
            event.practiceMode = PracticeMode.scheduled.rawValue
            event.wordEnglishSnapshot = english; event.wordChineseSnapshot = word.chinese
        }
        try context.save()
        return word
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
