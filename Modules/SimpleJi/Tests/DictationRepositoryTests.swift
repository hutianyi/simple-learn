import CoreData
import XCTest
import PencilKit
@testable import WordMemoryCards

@MainActor
final class DictationRepositoryTests: XCTestCase {
    private let timezone = TimeZone(secondsFromGMT: 0)!
    private let now = Date(timeIntervalSince1970: 1_788_192_000)

    func testAnswerComparisonPreservesWordBoundariesAndPunctuation() {
        XCTAssertTrue(DictationAnswerMatcher.matches("  APPLE  ", answer: "apple"))
        XCTAssertTrue(DictationAnswerMatcher.matches("a   part", answer: "a part"))
        XCTAssertTrue(DictationAnswerMatcher.matches("don’t", answer: "don't"))
        XCTAssertFalse(DictationAnswerMatcher.matches("a p p l e", answer: "apple"))
        XCTAssertFalse(DictationAnswerMatcher.matches("apart", answer: "a part"))
        XCTAssertFalse(DictationAnswerMatcher.matches("well known", answer: "well-known"))
        XCTAssertFalse(DictationAnswerMatcher.matches("dont", answer: "don't"))
        XCTAssertFalse(DictationAnswerMatcher.matches("color", answer: "colour"))
        XCTAssertFalse(DictationAnswerMatcher.matches("neccesary", answer: "necessary"))
    }

    func testEligibilityCountsOnlyFirstFormalAnswersOnDifferentDays() {
        let calendar = DictationEligibility.calendar(timeZone: timezone)
        let events = [
            cardEvent(at: now, result: .known),
            cardEvent(at: now.addingTimeInterval(60), result: .known),
            cardEvent(at: now.addingTimeInterval(86_400), result: .unknown),
            cardEvent(at: now.addingTimeInterval(86_460), result: .known),
            cardEvent(at: now.addingTimeInterval(172_800), result: .known, mode: .extraPractice),
            cardEvent(at: now.addingTimeInterval(259_200), result: .known, retry: true)
        ]
        XCTAssertFalse(DictationEligibility.qualifies(
            events: events, currentEnglish: "apple", calendar: calendar
        ))
        XCTAssertTrue(DictationEligibility.qualifies(
            events: events + [cardEvent(at: now.addingTimeInterval(345_600), result: .known)],
            currentEnglish: "apple", calendar: calendar
        ))
        XCTAssertFalse(DictationEligibility.qualifies(
            events: events + [cardEvent(at: now.addingTimeInterval(345_600), result: .known)],
            currentEnglish: "apples", calendar: calendar
        ))
    }

    func testInitialCopyStartsNextDayAndFormalAnswerIsUnique() async throws {
        let controller = PersistenceController(inMemory: true)
        let wordID = try seedEligibleWord(in: controller.container.viewContext)
        let repository = DictationRepository(
            container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone)
        )

        let copyQueue = try await repository.initialCopyQueue(now: now)
        XCTAssertEqual(copyQueue.map(\.wordID), [wordID])
        for count in 1...3 {
            let progress = try await repository.recordInitialCopy(
                wordID: wordID, recognized: "apple", now: now
            )
            XCTAssertEqual(progress.completedCopies, count)
        }
        let sameDay = try await repository.loadOrCreateDay(limit: 20, now: now)
        XCTAssertTrue(sameDay.items.isEmpty)

        let tomorrow = now.addingTimeInterval(86_400)
        let day = try await repository.loadOrCreateDay(limit: 20, now: tomorrow)
        XCTAssertEqual(day.items.map(\.wordID), [wordID])
        let submitted = try await repository.submitFormal(
            dayID: day.id, wordID: wordID, recognized: "APPLE", now: tomorrow
        )
        guard case .result(let result, let correct, _) = submitted else {
            return XCTFail("Expected a formal result")
        }
        XCTAssertTrue(correct)
        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(result.firstPassAccuracy, 1)
        do {
            _ = try await repository.submitFormal(
                dayID: day.id, wordID: wordID, recognized: "apple", now: tomorrow
            )
            XCTFail("A second rating on the same day must be rejected")
        } catch DictationRepository.DictationError.alreadyAnswered {
            // Expected.
        }
        let state = try XCTUnwrap(try controller.container.viewContext
            .fetch(DictationStateEntity.fetchRequest()).first)
        XCTAssertEqual(state.totalFormal, 1)
        XCTAssertNotNil(state.fsrsCardData)
        let events = try controller.container.viewContext.fetch(DictationEventEntity.fetchRequest())
        XCTAssertEqual(events.filter { $0.kind == "formal" }.count, 1)
        XCTAssertEqual(events.first { $0.kind == "formal" }?.recognizedText, "APPLE")
    }

    func testRemediationDoesNotRateFSRSAgain() async throws {
        let controller = PersistenceController(inMemory: true)
        let wordID = try seedEligibleWord(in: controller.container.viewContext)
        let repository = DictationRepository(
            container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone)
        )
        _ = try await repository.initialCopyQueue(now: now)
        for _ in 0..<3 {
            _ = try await repository.recordInitialCopy(wordID: wordID, recognized: "apple", now: now)
        }
        let tomorrow = now.addingTimeInterval(86_400)
        let day = try await repository.loadOrCreateDay(limit: 20, now: tomorrow)
        let first = try await repository.submitFormal(
            dayID: day.id, wordID: wordID, recognized: "aple", now: tomorrow
        )
        guard case .result(let afterFirst, let correct, _) = first else {
            return XCTFail("Expected first pass result")
        }
        XCTAssertFalse(correct)
        XCTAssertEqual(afterFirst.phase, .firstPassSummary)

        let context = controller.container.viewContext
        context.refreshAllObjects()
        let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest()).first)
        let cardAfterAgain = try XCTUnwrap(state.fsrsCardData)
        _ = try await repository.beginRemediation(dayID: day.id)
        for _ in 0..<3 {
            _ = try await repository.recordRemediationCopy(
                dayID: day.id, wordID: wordID, recognized: "apple", now: tomorrow
            )
        }
        let retest = try await repository.submitRetest(
            dayID: day.id, wordID: wordID, recognized: "apple", now: tomorrow
        )
        guard case .result(let finished, let passed, _) = retest else {
            return XCTFail("Expected retest result")
        }
        XCTAssertTrue(passed)
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertEqual(finished.firstPassAccuracy, 0)
        context.refreshAllObjects()
        XCTAssertEqual(state.fsrsCardData, cardAfterAgain)
        XCTAssertEqual(state.totalFormal, 1)
        let events = try context.fetch(DictationEventEntity.fetchRequest())
        XCTAssertEqual(events.filter { $0.kind == "formal" }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == "retest" }.count, 1)
    }

    func testInterruptedWritingRestartsThirtySecondsButPausedQuestionKeepsTime() async throws {
        let controller = PersistenceController(inMemory: true)
        let wordID = try seedEligibleWord(in: controller.container.viewContext)
        let repository = DictationRepository(
            container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone)
        )
        _ = try await repository.initialCopyQueue(now: now)
        for _ in 0..<3 {
            _ = try await repository.recordInitialCopy(wordID: wordID, recognized: "apple", now: now)
        }
        let tomorrow = now.addingTimeInterval(86_400)
        let day = try await repository.loadOrCreateDay(limit: 20, now: tomorrow)
        try await repository.setTimerState(
            dayID: day.id, wordID: wordID, remaining: 17, isWriting: true, now: tomorrow
        )
        let recovered = try await repository.loadOrCreateDay(limit: 20, now: tomorrow)
        XCTAssertEqual(recovered.items.first?.remainingSeconds, 30)
        XCTAssertEqual(recovered.items.first?.interruptionCount, 1)
        try await repository.setTimerState(
            dayID: day.id, wordID: wordID, remaining: 20, isWriting: false, now: tomorrow
        )
        let paused = try await repository.loadOrCreateDay(limit: 20, now: tomorrow)
        XCTAssertEqual(paused.items.first?.remainingSeconds, 20)
        XCTAssertEqual(paused.items.first?.interruptionCount, 1)
    }

    func testRestoringCompletedRemediationRepairsStalePhasesWithoutChangingResults() async throws {
        for phase in [DictationPhase.remediationCopy, .retest, .firstPassSummary, .firstPass] {
            for offset in [0.0, 86_400.0] {
                let (controller, repository, finished) = try await completedRemediationFixture()
                let context = controller.container.viewContext
                context.refreshAllObjects()
                let entity = try XCTUnwrap(try context.fetch(DictationDayEntity.fetchRequest()).first)
                let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest()).first)
                let fsrs = state.fsrsCardData
                let eventCount = try context.count(for: DictationEventEntity.fetchRequest())
                entity.phase = phase.rawValue
                try context.save()

                let restored = try await repository.loadOrCreateDay(
                    limit: 20, now: now.addingTimeInterval(offset)
                )
                context.refreshAllObjects()
                XCTAssertEqual(entity.phase, DictationPhase.complete.rawValue, "\(phase), offset \(offset)")
                XCTAssertEqual(try JSONDecoder().decode([DictationItem].self, from: entity.tasksData), finished.items)
                XCTAssertEqual(state.fsrsCardData, fsrs)
                XCTAssertEqual(state.totalFormal, 1)
                XCTAssertEqual(try context.count(for: DictationEventEntity.fetchRequest()), eventCount)
                if offset == 0 {
                    XCTAssertEqual(restored.id, finished.id)
                    XCTAssertEqual(restored.phase, .complete)
                    XCTAssertEqual(restored.firstPassWrong, 1)
                } else {
                    XCTAssertNotEqual(restored.id, finished.id)
                }
            }
        }
    }

    func testAdditionalBaselineWordsDoNotReopenAlreadyCompletedRemediation() async throws {
        let (controller, repository, finished) = try await completedRemediationFixture()
        let context = controller.container.viewContext
        let wordID = try seedBareWord("pear", chinese: "梨", at: now.addingTimeInterval(-86_400), in: context)
        try context.save()
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [wordID], activatedAt: now)
        let reopened = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        XCTAssertEqual(reopened.id, finished.id)
        XCTAssertEqual(reopened.phase, .firstPass)
        XCTAssertEqual(reopened.items.count, 2)
        let result = try await repository.submitFormal(dayID: reopened.id, wordID: wordID, recognized: "pear", now: now)
        guard case .result(let completed, let correct, _) = result else { return XCTFail("Expected formal result") }
        XCTAssertTrue(correct)
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertEqual(completed.firstPassWrong, 1)
        XCTAssertEqual(completed.unresolved, 0)
        XCTAssertEqual(completed.items.first, finished.items.first)
    }

    private func completedRemediationFixture() async throws -> (PersistenceController, DictationRepository, DictationDay) {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let wordID = try seedBareWord("apple", chinese: "苹果", at: now.addingTimeInterval(-86_400), in: context)
        try context.save()
        let repository = DictationRepository(container: controller.container,
                                            calendar: DictationEligibility.calendar(timeZone: timezone))
        let campaign = BaselineCampaignSnapshot(selectedWordIDs: [wordID], activatedAt: now)
        let day = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        _ = try await repository.submitFormal(dayID: day.id, wordID: wordID, recognized: "aple", now: now)
        _ = try await repository.beginRemediation(dayID: day.id, now: now)
        for _ in 0..<3 {
            _ = try await repository.recordRemediationCopy(dayID: day.id, wordID: wordID, recognized: "apple", now: now)
        }
        let result = try await repository.submitRetest(dayID: day.id, wordID: wordID, recognized: "apple", now: now)
        guard case .result(let finished, let correct, _) = result else {
            throw DictationRepository.DictationError.invalidPhase
        }
        XCTAssertTrue(correct)
        XCTAssertEqual(finished.phase, .complete)
        return (controller, repository, finished)
    }

    func testAutomaticBaselineExcludesTodaysWordsAndUsesFiftyPerDay() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let oldIDs = try (0..<51).map { index in
            try seedBareWord("word\(index)", chinese: "旧词\(index)",
                             at: now.addingTimeInterval(-86_400 + Double(index)), in: context)
        }
        let newWord = try seedBareWord("melon", chinese: "甜瓜", at: now, in: context)
        try context.save()
        let repository = DictationRepository(
            container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone)
        )
        let initiallyEmpty = try await repository.loadOrCreateDay(limit: 20, now: now)
        XCTAssertTrue(initiallyEmpty.items.isEmpty)
        let campaign = try await repository.automaticBaselineCampaign(now: now)
        XCTAssertEqual(campaign.selectedWordIDs, oldIDs)
        XCTAssertFalse(campaign.selectedWordIDs.contains(newWord))
        let firstDay = try await repository.loadOrCreateDay(
            limit: 0, campaign: campaign, now: now
        )
        XCTAssertEqual(firstDay.id, initiallyEmpty.id)
        XCTAssertEqual(firstDay.limit, 50)
        XCTAssertEqual(firstDay.items.map(\.wordID), Array(oldIDs.prefix(50)))
        XCTAssertTrue(firstDay.items.allSatisfy(\.belongsToBaseline))
        for index in 0..<50 {
            let answer = try await repository.submitFormal(
                dayID: firstDay.id, wordID: oldIDs[index],
                recognized: "word\(index)", now: now
            )
            guard case .result = answer else { return XCTFail("Expected a baseline result") }
        }
        let progress = try await repository.baselineProgress(for: campaign)
        XCTAssertEqual(progress, BaselineProgress(total: 51, completed: 50))
        let sameDay = try await repository.loadOrCreateDay(
            limit: 0, campaign: campaign, now: now
        )
        XCTAssertEqual(sameDay.items.count, 50)
        let tomorrow = now.addingTimeInterval(86_400)
        let secondDay = try await repository.loadOrCreateDay(
            limit: 0, campaign: campaign, now: tomorrow
        )
        XCTAssertEqual(secondDay.limit, 50)
        XCTAssertEqual(secondDay.items.map(\.wordID), [oldIDs[50]])
        XCTAssertFalse(secondDay.items.contains { $0.wordID == newWord })
        let wrong = try await repository.submitFormal(
            dayID: secondDay.id, wordID: oldIDs[50], recognized: "incorrect", now: tomorrow
        )
        guard case .result(let needsPractice, let passed, _) = wrong else {
            return XCTFail("Expected a wrong baseline result")
        }
        XCTAssertFalse(passed)
        XCTAssertEqual(needsPractice.phase, .firstPassSummary)
        let completedProgress = try await repository.baselineProgress(for: campaign)
        XCTAssertEqual(completedProgress, BaselineProgress(total: 51, completed: 51))
        _ = try await repository.beginRemediation(dayID: secondDay.id, now: tomorrow)
        for _ in 0..<3 {
            _ = try await repository.recordRemediationCopy(
                dayID: secondDay.id, wordID: oldIDs[50],
                recognized: "word50", now: tomorrow
            )
        }
        _ = try await repository.submitRetest(
            dayID: secondDay.id, wordID: oldIDs[50], recognized: "word50", now: tomorrow
        )
        context.refreshAllObjects()
        let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest())
            .first { $0.wordID == oldIDs[50] })
        XCTAssertEqual(state.totalFormal, 1)
        let formal = try context.fetch(DictationEventEntity.fetchRequest())
            .filter { $0.kind == "baselineFormal" }
        XCTAssertEqual(formal.count, 51)
        let copies = try await repository.initialCopyQueue(campaign: campaign, now: tomorrow)
        XCTAssertTrue(copies.isEmpty)
        let regularDay = try await repository.loadOrCreateDay(
            limit: 20, campaign: campaign, now: tomorrow.addingTimeInterval(86_400)
        )
        XCTAssertEqual(regularDay.limit, 20)
        XCTAssertFalse(regularDay.items.contains(where: \.belongsToBaseline))
    }

    func testMasteredTermIsExcludedFromExistingDayAndFutureDictation() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let tv = try seedBareWord("TV", chinese: "电视", at: now.addingTimeInterval(-86_400), in: context)
        let phone = try seedBareWord("phone", chinese: "电话", at: now.addingTimeInterval(-86_399), in: context)
        let apple = try seedBareWord("apple", chinese: "苹果", at: now.addingTimeInterval(-86_398), in: context)
        try context.save()
        let repository = DictationRepository(
            container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone)
        )
        let campaign = try await repository.automaticBaselineCampaign(now: now)
        let originalDay = try await repository.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        XCTAssertEqual(originalDay.items.map(\.wordID), [tv, phone, apple])

        let mastered: Set<String> = ["tv", "phone", "computer"]
        let updatedDay = try await repository.loadOrCreateDay(
            limit: 20, campaign: campaign, masteredTerms: mastered, now: now
        )
        XCTAssertEqual(updatedDay.id, originalDay.id)
        XCTAssertEqual(updatedDay.items.map(\.wordID), [apple])
        let progress = try await repository.baselineProgress(
            for: campaign, masteredTerms: mastered
        )
        XCTAssertEqual(progress, BaselineProgress(total: 1, completed: 0))
        let freshCampaign = try await repository.automaticBaselineCampaign(
            masteredTerms: mastered, now: now
        )
        XCTAssertEqual(freshCampaign.selectedWordIDs, [apple])
    }

    func testMasteredTermNeverStartsInitialCopy() async throws {
        let controller = PersistenceController(inMemory: true)
        let wordID = try seedEligibleWord(in: controller.container.viewContext)
        let repository = DictationRepository(
            container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone)
        )
        let queue = try await repository.initialCopyQueue(
            masteredTerms: ["apple"], now: now
        )
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(try controller.container.viewContext
            .count(for: DictationStateEntity.fetchRequest()), 0)
        XCTAssertNotNil(try controller.container.viewContext
            .fetch(WordEntity.fetchRequest()).first { $0.id == wordID })
    }

    func testInitialKeyboardRequiresThreeConsecutiveFailuresAndPreservesNextDayGate() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let id = try seedEligibleWord(in: context)
        let repo = DictationRepository(container: controller.container,
                                      calendar: DictationEligibility.calendar(timeZone: timezone))
        _ = try await repo.initialCopyQueue(now: now)
        do {
            _ = try await repo.recordInitialCopy(wordID: id, recognized: "apple", viaKeyboard: true, now: now)
            XCTFail("Keyboard must be locked before three failures")
        } catch DictationRepository.DictationError.invalidPhase {}
        for (index, text) in ["aple", "aple", "apple", "aple", "aple"].enumerated() {
            _ = try await repo.recordInitialCopy(wordID: id, recognized: text, now: now.addingTimeInterval(Double(index + 1)))
        }
        let before = try await repo.initialCopyQueue(now: now.addingTimeInterval(6))
        XCTAssertFalse(try XCTUnwrap(before.first).keyboardAllowed)
        let unlocked = try await repo.recordInitialCopy(wordID: id, recognized: "aple", now: now.addingTimeInterval(7))
        XCTAssertTrue(unlocked.keyboardAllowed)
        XCTAssertEqual(unlocked.consecutiveFailures, 3)
        let restarted = DictationRepository(container: controller.container,
                                           calendar: DictationEligibility.calendar(timeZone: timezone))
        let resumed = try await restarted.initialCopyQueue(now: now.addingTimeInterval(8))
        XCTAssertTrue(try XCTUnwrap(resumed.first).keyboardAllowed)
        let wrong = try await restarted.recordInitialCopy(wordID: id, recognized: "aple", viaKeyboard: true, now: now.addingTimeInterval(9))
        XCTAssertEqual(wrong.completedCopies, 1)
        let completed = try await restarted.recordInitialCopy(wordID: id, recognized: "APPLE", viaKeyboard: true, now: now.addingTimeInterval(10))
        XCTAssertEqual(completed.completedCopies, 3)
        let today = try await restarted.loadOrCreateDay(limit: 20, now: now.addingTimeInterval(11))
        XCTAssertTrue(today.items.isEmpty)
        let tomorrow = try await restarted.loadOrCreateDay(limit: 20, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(tomorrow.items.map(\.wordID), [id])
        context.refreshAllObjects()
        let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest()).first)
        XCTAssertEqual(state.totalFormal, 0)
        XCTAssertEqual(try context.fetch(DictationEventEntity.fetchRequest()).filter { $0.kind == "initialCopyKeyboard" }.count, 2)
    }

    func testRemediationKeyboardAndRetestNeverRewriteFirstScoreOrFSRS() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let id = try seedBareWord("gas", chinese: "气体", at: now.addingTimeInterval(-86_400), in: context)
        try context.save()
        let repo = DictationRepository(container: controller.container,
                                      calendar: DictationEligibility.calendar(timeZone: timezone))
        let campaign = try await repo.automaticBaselineCampaign(now: now)
        let day = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        _ = try await repo.submitFormal(dayID: day.id, wordID: id, recognized: "qas", now: now)
        _ = try await repo.beginRemediation(dayID: day.id, now: now)
        context.refreshAllObjects()
        let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest()).first)
        let fsrs = state.fsrsCardData
        _ = try await repo.deferRemediation(dayID: day.id, wordID: id, now: now)
        let afterPause = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        XCTAssertEqual(afterPause.phase, .remediationCopy)
        do {
            _ = try await repo.recordRemediationCopy(dayID: day.id, wordID: id, recognized: "gas", viaKeyboard: true, now: now)
            XCTFail("Must not bypass handwriting before the threshold")
        } catch DictationRepository.DictationError.invalidPhase {}
        // A correct handwritten copy resets the consecutive-failure counter.
        for text in ["qas", "qas", "gas", "qas", "qas"] {
            _ = try await repo.recordRemediationCopy(dayID: day.id, wordID: id, recognized: text, now: now)
        }
        let before = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        XCTAssertFalse(try XCTUnwrap(before.items.first).allowsKeyboard)
        let third = try await repo.recordRemediationCopy(dayID: day.id, wordID: id, recognized: "qas", now: now)
        XCTAssertTrue(try XCTUnwrap(third.items.first).allowsKeyboard)
        let resumed = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        XCTAssertTrue(try XCTUnwrap(resumed.items.first).allowsKeyboard)
        let wrong = try await repo.recordRemediationCopy(dayID: day.id, wordID: id, recognized: "qas", viaKeyboard: true, now: now)
        XCTAssertEqual(wrong.items.first?.remediationCopyCount, 1)
        let copied = try await repo.recordRemediationCopy(dayID: day.id, wordID: id, recognized: "gas", viaKeyboard: true, now: now)
        XCTAssertEqual(copied.phase, .retest)
        XCTAssertEqual(copied.items.first?.remainingSeconds, 30)
        let suiteForModel = "DictationHandwritingOnly-\(UUID())"
        let defaultsForModel = try XCTUnwrap(UserDefaults(suiteName: suiteForModel))
        defer { defaultsForModel.removePersistentDomain(forName: suiteForModel) }
        let store = SettingsStore(defaults: defaultsForModel)
        store.baselineCampaign = campaign
        let model = DictationViewModel(container: controller.container, settings: store)
        await model.start()
        XCTAssertEqual(model.day?.phase, .retest)
        XCTAssertFalse(model.keyboardAllowed)
        let denied = await model.submitKeyboard("gas")
        XCTAssertFalse(denied)
        XCTAssertFalse(try XCTUnwrap(model.activeItem).remediationPassed)
        let failedRetest = try await repo.submitRetest(dayID: day.id, wordID: id, recognized: "qas", now: now)
        guard case .result(let again, let correct, _) = failedRetest else { return XCTFail("Expected handwritten retest") }
        XCTAssertFalse(correct)
        XCTAssertEqual(again.phase, .remediationCopy)
        XCTAssertTrue(try XCTUnwrap(again.items.first).allowsKeyboard)
        _ = try await repo.recordRemediationCopy(dayID: day.id, wordID: id, recognized: "gas", viaKeyboard: true, now: now)
        let final = try await repo.submitRetest(dayID: day.id, wordID: id, recognized: "gas", now: now)
        guard case .result(let finished, let passed, _) = final else { return XCTFail("Expected completion") }
        XCTAssertTrue(passed)
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertEqual(finished.firstPassAccuracy, 0)
        context.refreshAllObjects()
        XCTAssertEqual(state.totalFormal, 1)
        XCTAssertEqual(state.fsrsCardData, fsrs)
        let events = try context.fetch(DictationEventEntity.fetchRequest())
        XCTAssertEqual(events.filter { $0.kind == "baselineFormal" }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == "retest" }.count, 2)
        XCTAssertTrue(events.filter { $0.kind.hasSuffix("Keyboard") }.allSatisfy { $0.formalKey == nil && $0.fsrsAfter == nil })
        // New assistance records and optional queue fields survive full backup/restore.
        let settings = BackupSettings(sessionLimit: 30, englishVoiceIdentifier: nil,
            chineseVoiceIdentifier: nil, englishSpeechRate: 0.46, chineseSpeechRate: 0.46,
            autoSpeakFront: true, autoSpeakBack: true, hapticsEnabled: true,
            extraPracticeScope: ExtraPracticeScope.weakest20.rawValue,
            baselineCampaign: campaign)
        let envelope = try await BackupService.makeEnvelope(container: controller.container,
            settings: settings, appVersion: "2.0")
        let decoded = try BackupService.decodeAndValidate(BackupService.encode(envelope))
        let target = PersistenceController(inMemory: true)
        try await BackupService.restore(decoded, into: target.container)
        let restored = try XCTUnwrap(try target.container.viewContext.fetch(DictationDayEntity.fetchRequest()).first)
        XCTAssertTrue(try XCTUnwrap(JSONDecoder().decode([DictationItem].self, from: restored.tasksData).first).allowsKeyboard)
        XCTAssertEqual(try target.container.viewContext.fetch(DictationEventEntity.fetchRequest()).filter { $0.kind == "retest" }.count, 2)
        XCTAssertEqual(try target.container.viewContext.fetch(DictationEventEntity.fetchRequest()).filter { $0.kind == "deferred" }.count, 1)
        XCTAssertEqual(try target.container.viewContext.fetch(DictationEventEntity.fetchRequest()).filter { $0.kind == "remediationCopyKeyboard" }.count, 3)
    }

    func testDeferredWordAllowsOthersToFinishAndResumesWithoutSkippingRequiredCopies() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let gas = try seedBareWord("gas", chinese: "气体", at: now.addingTimeInterval(-86_400), in: context)
        let lamp = try seedBareWord("lamp", chinese: "灯", at: now.addingTimeInterval(-86_399), in: context)
        try context.save()
        let repo = DictationRepository(container: controller.container,
                                      calendar: DictationEligibility.calendar(timeZone: timezone))
        let campaign = try await repo.automaticBaselineCampaign(now: now)
        let day = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        for id in [gas, lamp] { _ = try await repo.submitFormal(dayID: day.id, wordID: id, recognized: "wrong", now: now) }
        _ = try await repo.beginRemediation(dayID: day.id, now: now)
        let skipped = try await repo.deferRemediation(dayID: day.id, wordID: gas, now: now)
        XCTAssertEqual(skipped.unresolved, 2)
        XCTAssertEqual(skipped.items.first?.formalResult, false)
        for _ in 0..<3 { _ = try await repo.recordRemediationCopy(dayID: day.id, wordID: lamp, recognized: "lamp", now: now) }
        let outcome = try await repo.submitRetest(dayID: day.id, wordID: lamp, recognized: "lamp", now: now)
        guard case .result(let partial, _, _) = outcome else { return XCTFail("Expected retest") }
        XCTAssertNotEqual(partial.phase, .complete)
        XCTAssertEqual(partial.unresolved, 1)
        XCTAssertTrue(try XCTUnwrap(partial.items.first).isDeferred)
        let resumed = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(resumed.id, day.id)
        XCTAssertEqual(resumed.phase, .remediationCopy)
        XCTAssertFalse(try XCTUnwrap(resumed.items.first).isDeferred)
        XCTAssertEqual(resumed.items.first?.remediationCopyCount, 0)
        do {
            _ = try await repo.submitRetest(dayID: day.id, wordID: gas, recognized: "gas", now: now)
            XCTFail("Deferred word still requires copies")
        } catch DictationRepository.DictationError.invalidPhase {}
    }

    func testExcludingUnfinishedCopyStillLetsReadyWordsReachHandwrittenRetest() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let gas = try seedBareWord("gas", chinese: "气体", at: now.addingTimeInterval(-86_400), in: context)
        let lamp = try seedBareWord("lamp", chinese: "灯", at: now.addingTimeInterval(-86_399), in: context)
        try context.save()
        let repo = DictationRepository(container: controller.container,
                                      calendar: DictationEligibility.calendar(timeZone: timezone))
        let campaign = try await repo.automaticBaselineCampaign(now: now)
        let day = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        for id in [gas, lamp] { _ = try await repo.submitFormal(dayID: day.id, wordID: id, recognized: "wrong", now: now) }
        _ = try await repo.beginRemediation(dayID: day.id, now: now)
        for _ in 0..<3 { _ = try await repo.recordRemediationCopy(dayID: day.id, wordID: lamp, recognized: "lamp", now: now) }
        let filtered = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, masteredTerms: ["gas"], now: now)
        XCTAssertEqual(filtered.items.map(\.wordID), [lamp])
        XCTAssertEqual(filtered.phase, .retest)
        let outcome = try await repo.submitRetest(dayID: day.id, wordID: lamp, recognized: "lamp", now: now)
        guard case .result(let completed, let correct, _) = outcome else { return XCTFail("Expected retest") }
        XCTAssertTrue(correct)
        XCTAssertEqual(completed.phase, .complete)
    }

    func testFormalStagesMismatchWithoutShowingAnswerOrScoringUntilDecision() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        _ = try seedBareWord("gas", chinese: "气体", at: Date().addingTimeInterval(-86_400), in: context)
        try context.save()
        let suite = "DictationFormal-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DictationViewModel(container: controller.container,
            settings: SettingsStore(defaults: defaults), recognition: { _ in "qas" })
        await model.start()
        XCTAssertEqual(model.day?.phase, .firstPass)
        XCTAssertFalse(model.keyboardAllowed)
        let denied = await model.submitKeyboard("gas")
        XCTAssertFalse(denied)
        XCTAssertNil(model.activeItem?.formalResult)
        _ = await model.submit(drawing: PKDrawing())
        XCTAssertTrue(model.awaitsVerification)
        XCTAssertTrue(model.verificationMessage.contains("qas"))
        XCTAssertNil(model.day?.firstPassAccuracy)
        XCTAssertNil(model.feedback)
        XCTAssertNil(model.activeItem?.formalResult)
        await model.acceptHandwritingResult()
        XCTAssertEqual(model.day?.firstPassAccuracy, 0)
        XCTAssertNotNil(model.feedback)
    }

    func testOldQueueJSONDecodesWithoutAssistanceFields() throws {
        let item = DictationItem(wordID: UUID(), english: "gas", chinese: "气体")
        let data = try JSONEncoder().encode(item)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["consecutiveCopyFailures", "keyboardAllowed", "deferred", "pendingHandwriting", "keyboardDeadline", "formalInputMethod", "retestInputMethod"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(DictationItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.allowsKeyboard)
        XCTAssertFalse(old.isDeferred)
        XCTAssertNil(old.consecutiveCopyFailures)
    }

    func testRecognitionPopupPreservesExactRecognizedTextAndKeyboardUnlocksAfterThreeCopies() async throws {
        let controller = PersistenceController(inMemory: true)
        _ = try seedEligibleWord(in: controller.container.viewContext)
        let repo = DictationRepository(container: controller.container)
        _ = try await repo.initialCopyQueue(now: now)
        let suite = "DictationUI-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DictationViewModel(container: controller.container,
            settings: SettingsStore(defaults: defaults), recognition: { _ in "a p l e" })
        await model.startInitialCopy()
        for index in 1...3 {
            _ = await model.submit(drawing: PKDrawing(), submittedAt: now.addingTimeInterval(Double(index)))
            XCTAssertTrue(try XCTUnwrap(model.recognitionNotice).contains("a p l e"))
            model.dismissRecognitionNotice()
            XCTAssertEqual(model.keyboardAllowed, index >= 3)
        }
        let rejected = await model.submitKeyboard("aple")
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.activeCopy?.completedCopies, 0)
        let accepted = await model.submitKeyboard("apple")
        XCTAssertTrue(accepted)
        XCTAssertNil(model.activeCopy)
    }

    func testKeyboardVerificationCorrectAnswerScoresOnceAfterStaging() async throws {
        let (controller, repo, day, ids, _) = try await verificationFixture()
        let staged = try await repo.stageVerification(dayID: day.id, wordID: ids[0], recognized: "hat", now: now)
        XCTAssertNil(staged.items.first?.formalResult)
        XCTAssertEqual(staged.items.first?.pendingHandwriting, "hat")
        let context = controller.container.viewContext
        XCTAssertEqual(try context.count(for: DictationStateEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.fetch(DictationEventEntity.fetchRequest()).filter { $0.kind == "baselineFormal" }.count, 0)
        let started = try await repo.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: now)
        XCTAssertEqual(started.items.first?.keyboardDeadline, now.addingTimeInterval(60))
        let result = try await repo.submitFormal(dayID: day.id, wordID: ids[0], recognized: "gas",
            resolvingVerification: true, viaKeyboard: true, now: now.addingTimeInterval(40))
        guard case .result(let finished, let correct, _) = result else { return XCTFail("Expected final grade") }
        XCTAssertTrue(correct)
        XCTAssertEqual(finished.firstPassAccuracy, 1)
        XCTAssertEqual(finished.items.first?.formalInputMethod, "keyboard")
        XCTAssertNil(finished.items.first?.pendingHandwriting)
        context.refreshAllObjects()
        let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest()).first)
        XCTAssertEqual(state.totalFormal, 1)
        let events = try context.fetch(DictationEventEntity.fetchRequest())
        XCTAssertEqual(events.filter { $0.kind == "baselineFormal" }.count, 1)
        XCTAssertEqual(events.first { $0.kind == "recognitionMismatch" }?.recognizedText, "hat")
        XCTAssertEqual(events.first { $0.kind == "keyboardVerification" }?.recognizedText, "gas")
        XCTAssertEqual(events.first { $0.kind == "keyboardVerification" }?.remainingSeconds, 20)
    }

    func testWrongKeyboardAnswerAdvancesAndRejectsASecondAttempt() async throws {
        let (controller, repo, day, ids, _) = try await verificationFixture(wordCount: 2)
        _ = try await repo.stageVerification(dayID: day.id, wordID: ids[0], recognized: "hat", now: now)
        _ = try await repo.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: now)
        let result = try await repo.submitFormal(dayID: day.id, wordID: ids[0], recognized: "hat",
            resolvingVerification: true, viaKeyboard: true, now: now.addingTimeInterval(20))
        guard case .result(let next, let correct, let reason) = result else { return XCTFail("Expected final grade") }
        XCTAssertFalse(correct)
        XCTAssertEqual(reason, .spelling)
        XCTAssertEqual(next.items.first { $0.formalResult == nil }?.wordID, ids[1])
        do {
            _ = try await repo.submitFormal(dayID: day.id, wordID: ids[0], recognized: "gas",
                resolvingVerification: true, viaKeyboard: true, now: now.addingTimeInterval(21))
            XCTFail("A second keyboard submission must be rejected")
        } catch DictationRepository.DictationError.alreadyAnswered {}
        let states = try controller.container.viewContext.fetch(DictationStateEntity.fetchRequest())
        XCTAssertEqual(states.first?.totalFormal, 1)
        let settings = BackupSettings(sessionLimit: 30, englishVoiceIdentifier: nil, chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46, chineseSpeechRate: 0.46, autoSpeakFront: true, autoSpeakBack: true,
            hapticsEnabled: true, extraPracticeScope: ExtraPracticeScope.weakest20.rawValue)
        let envelope = try await BackupService.makeEnvelope(container: controller.container, settings: settings, appVersion: "2.0")
        let decoded = try BackupService.decodeAndValidate(BackupService.encode(envelope))
        XCTAssertEqual(decoded.data.dictationEvents?.first { $0.kind == "keyboardVerification" }?.remainingSeconds, 40)
    }

    func testKeyboardDeadlinePersistsAndCorrectTextAtSixtySecondsStillTimesOut() async throws {
        let (controller, repo, day, ids, campaign) = try await verificationFixture()
        _ = try await repo.stageVerification(dayID: day.id, wordID: ids[0], recognized: "hat", now: now)
        _ = try await repo.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: now)
        let restarted = DictationRepository(container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone))
        let resumed = try await restarted.loadOrCreateDay(limit: 20, campaign: campaign, now: now.addingTimeInterval(25))
        XCTAssertEqual(resumed.items.first?.pendingHandwriting, "hat")
        let reopened = try await restarted.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: now.addingTimeInterval(25))
        XCTAssertEqual(reopened.items.first?.keyboardDeadline, now.addingTimeInterval(60))
        XCTAssertEqual(DictationKeyboardClock.remaining(until: now.addingTimeInterval(60), now: now.addingTimeInterval(25)), 35)
        let result = try await restarted.submitFormal(dayID: day.id, wordID: ids[0], recognized: "gas",
            resolvingVerification: true, viaKeyboard: true, now: now.addingTimeInterval(60))
        guard case .result(let finished, let correct, let reason) = result else { return XCTFail("Expected timeout") }
        XCTAssertFalse(correct)
        XCTAssertEqual(reason, .timeout)
        XCTAssertEqual(finished.items.first?.formalReason, .timeout)
        XCTAssertEqual(DictationKeyboardClock.remaining(until: now.addingTimeInterval(60), now: now.addingTimeInterval(90)), 0)
    }

    func testVerificationBackupAndMidnightRecoveryKeepOriginalDeadline() async throws {
        let (controller, repo, day, ids, _) = try await verificationFixture()
        _ = try await repo.stageVerification(dayID: day.id, wordID: ids[0], recognized: "hat", now: now)
        _ = try await repo.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: now)
        let settings = BackupSettings(sessionLimit: 30, englishVoiceIdentifier: nil, chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46, chineseSpeechRate: 0.46, autoSpeakFront: true, autoSpeakBack: true,
            hapticsEnabled: true, extraPracticeScope: ExtraPracticeScope.weakest20.rawValue)
        let envelope = try await BackupService.makeEnvelope(container: controller.container, settings: settings, appVersion: "2.0")
        let decoded = try BackupService.decodeAndValidate(BackupService.encode(envelope))
        let restored = PersistenceController(inMemory: true)
        try await BackupService.restore(decoded, into: restored.container)
        let newRepo = DictationRepository(container: restored.container,
            calendar: DictationEligibility.calendar(timeZone: timezone))
        let nextDay = try await newRepo.loadOrCreateDay(limit: 20, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(nextDay.id, day.id)
        XCTAssertEqual(nextDay.phase, .firstPass)
        XCTAssertEqual(nextDay.items.first?.keyboardDeadline, now.addingTimeInterval(60))
        XCTAssertEqual(nextDay.items.first?.pendingHandwriting, "hat")
        let result = try await newRepo.submitFormal(dayID: day.id, wordID: ids[0], recognized: "gas",
            resolvingVerification: true, viaKeyboard: true, now: now.addingTimeInterval(86_400))
        guard case .result(_, let correct, let reason) = result else { return XCTFail("Expected expired final grade") }
        XCTAssertFalse(correct)
        XCTAssertEqual(reason, .timeout)
    }

    func testBlankKeyboardAnswerIsFinalWrongAnswerWithoutRecognitionRetry() async throws {
        let (_, repo, day, ids, _) = try await verificationFixture()
        _ = try await repo.stageVerification(dayID: day.id, wordID: ids[0], recognized: nil, now: now)
        _ = try await repo.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: now)
        let result = try await repo.submitFormal(dayID: day.id, wordID: ids[0], recognized: "",
            resolvingVerification: true, viaKeyboard: true, now: now.addingTimeInterval(10))
        guard case .result(_, let correct, let reason) = result else { return XCTFail("A keyboard answer cannot get an OCR retry") }
        XCTAssertFalse(correct)
        XCTAssertEqual(reason, .spelling)
    }

    func testRetestKeyboardVerificationDoesNotRateFormalFSRSAgain() async throws {
        let (controller, repo, day, ids, _) = try await verificationFixture()
        _ = try await repo.submitFormal(dayID: day.id, wordID: ids[0], recognized: "wrong", now: now)
        _ = try await repo.beginRemediation(dayID: day.id, now: now)
        for _ in 0..<3 { _ = try await repo.recordRemediationCopy(dayID: day.id, wordID: ids[0], recognized: "gas", now: now) }
        let context = controller.container.viewContext
        context.refreshAllObjects()
        let state = try XCTUnwrap(try context.fetch(DictationStateEntity.fetchRequest()).first)
        let card = state.fsrsCardData
        _ = try await repo.stageVerification(dayID: day.id, wordID: ids[0], recognized: "hat", now: now)
        _ = try await repo.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: now)
        let result = try await repo.submitRetest(dayID: day.id, wordID: ids[0], recognized: "gas",
            resolvingVerification: true, viaKeyboard: true, now: now.addingTimeInterval(20))
        guard case .result(let finished, let correct, _) = result else { return XCTFail("Expected retest result") }
        XCTAssertTrue(correct)
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertEqual(finished.firstPassAccuracy, 0)
        XCTAssertEqual(finished.items.first?.retestInputMethod, "keyboard")
        context.refreshAllObjects()
        XCTAssertEqual(state.totalFormal, 1)
        XCTAssertEqual(state.fsrsCardData, card)
    }

    func testViewModelKeyboardCompletesWrongAnswerWithoutOfferingAnotherAttempt() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        _ = try seedBareWord("gas", chinese: "气体", at: Date().addingTimeInterval(-86_400), in: context)
        try context.save()
        let suite = "DictationOnce-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DictationViewModel(container: controller.container,
            settings: SettingsStore(defaults: defaults), recognition: { _ in "hat" })
        await model.start()
        _ = await model.submit(drawing: PKDrawing())
        XCTAssertTrue(model.awaitsVerification)
        XCTAssertNil(model.feedback)
        let deadline = await model.beginVerificationKeyboard()
        XCTAssertNotNil(deadline)
        let closed = await model.submitKeyboard("hat")
        XCTAssertTrue(closed)
        XCTAssertFalse(model.awaitsVerification)
        XCTAssertEqual(model.day?.firstPassAccuracy, 0)
        XCTAssertNotNil(model.feedback)
        let second = await model.submitKeyboard("gas")
        XCTAssertFalse(second)
        XCTAssertEqual(model.day?.firstPassAccuracy, 0)
    }

    func testViewModelReopeningExpiredKeyboardFinalizesTimeoutWithoutFreshMinute() async throws {
        let (controller, repo, day, ids, campaign) = try await verificationFixture()
        _ = try await repo.stageVerification(dayID: day.id, wordID: ids[0], recognized: "hat", now: now)
        _ = try await repo.beginKeyboardVerification(dayID: day.id, wordID: ids[0], now: Date().addingTimeInterval(-61))
        let suite = "DictationExpired-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.baselineCampaign = campaign
        let model = DictationViewModel(container: controller.container, settings: settings)
        await model.start()
        XCTAssertFalse(model.awaitsVerification)
        XCTAssertEqual(model.day?.items.first?.formalResult, false)
        XCTAssertEqual(model.day?.items.first?.formalReason, .timeout)
        XCTAssertEqual(model.feedback?.reason, .timeout)
        let context = controller.container.viewContext
        context.refreshAllObjects()
        XCTAssertEqual(try context.fetch(DictationStateEntity.fetchRequest()).first?.totalFormal, 1)
    }

    func testCopyKeyboardTimeoutDoesNotCompleteEvenWithMatchingTypedWord() async throws {
        let controller = PersistenceController(inMemory: true)
        let id = try seedEligibleWord(in: controller.container.viewContext)
        let repo = DictationRepository(container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone))
        _ = try await repo.initialCopyQueue(now: now)
        for index in 0..<3 {
            _ = try await repo.recordInitialCopy(wordID: id, recognized: "aple", now: now.addingTimeInterval(Double(index)))
        }
        let result = try await repo.recordInitialCopy(wordID: id, recognized: "apple", viaKeyboard: true,
            explicitReason: .timeout, now: now.addingTimeInterval(60))
        XCTAssertEqual(result.completedCopies, 0)
        controller.container.viewContext.refreshAllObjects()
        XCTAssertNil(try controller.container.viewContext.fetch(DictationStateEntity.fetchRequest()).first?.initialCopyCompletedAt)
        let timeout = try controller.container.viewContext.fetch(DictationEventEntity.fetchRequest()).first { $0.kind == "initialCopyKeyboard" }
        XCTAssertEqual(timeout?.result, "incorrect")
        XCTAssertEqual(timeout?.reason, "timeout")
    }

    func testLoweringUnlimitedDayAppliesImmediatelyAndKeepsOverduePriority() async throws {
        let (controller, repository, ids) = try regularLimitFixture(count: 113)
        let original = try await repository.loadOrCreateDay(limit: 0, now: now)
        XCTAssertEqual(original.items.count, 113)
        let limited = try await repository.loadOrCreateDay(limit: 50, now: now)
        XCTAssertEqual(limited.id, original.id)
        XCTAssertEqual(limited.limit, 50)
        XCTAssertEqual(limited.items.map(\.wordID), Array(ids.prefix(50)))
        let reopened = try await repository.loadOrCreateDay(limit: 50, now: now)
        XCTAssertEqual(reopened.items, limited.items)
        let context = controller.container.viewContext
        context.refreshAllObjects()
        XCTAssertEqual(try context.count(for: DictationEventEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.fetch(DictationStateEntity.fetchRequest()).filter { $0.lastFormalDay != nil }.count, 0)

        for index in 0..<50 {
            _ = try await repository.submitFormal(dayID: limited.id, wordID: ids[index],
                recognized: "word\(index)", now: now)
        }
        let tomorrow = try await repository.loadOrCreateDay(limit: 50, now: now.addingTimeInterval(86_400))
        XCTAssertTrue(Set(ids[50...]).isSuperset(of: Set(tomorrow.items.map(\.wordID))))
        XCTAssertEqual(tomorrow.items.count, 50)
    }

    func testRaisingLimitReopensCompletedDayAndUnlimitedAddsRemainingWords() async throws {
        let (_, repository, ids) = try regularLimitFixture(count: 15)
        let day = try await repository.loadOrCreateDay(limit: 3, now: now)
        for index in 0..<3 {
            _ = try await repository.submitFormal(dayID: day.id, wordID: ids[index],
                recognized: "word\(index)", now: now)
        }
        let expanded = try await repository.loadOrCreateDay(limit: 10, now: now)
        XCTAssertEqual(expanded.id, day.id)
        XCTAssertEqual(expanded.items.count, 10)
        XCTAssertEqual(expanded.firstPassAnswered, 3)
        XCTAssertEqual(expanded.phase, .firstPass)
        let unlimited = try await repository.loadOrCreateDay(limit: 0, now: now)
        XCTAssertEqual(unlimited.items.count, 15)
        XCTAssertEqual(unlimited.firstPassAnswered, 3)
        XCTAssertEqual(Set(unlimited.items.map(\.wordID)).count, 15)
    }

    func testLoweringBelowAnsweredCountKeepsResultsAndRequiresWrongWordRemediation() async throws {
        let (controller, repository, ids) = try regularLimitFixture(count: 15)
        let day = try await repository.loadOrCreateDay(limit: 0, now: now)
        for index in 0..<12 {
            _ = try await repository.submitFormal(dayID: day.id, wordID: ids[index],
                recognized: index == 0 ? "wrong" : "word\(index)", now: now)
        }
        let context = controller.container.viewContext
        context.refreshAllObjects()
        let cardsBefore = try context.fetch(DictationStateEntity.fetchRequest()).map { $0.fsrsCardData }
        let limited = try await repository.loadOrCreateDay(limit: 10, now: now)
        XCTAssertEqual(limited.limit, 10)
        XCTAssertEqual(limited.items.count, 12)
        XCTAssertEqual(limited.firstPassAnswered, 12)
        XCTAssertEqual(limited.firstPassWrong, 1)
        XCTAssertEqual(limited.phase, .firstPassSummary)
        context.refreshAllObjects()
        XCTAssertEqual(try context.fetch(DictationStateEntity.fetchRequest()).map { $0.fsrsCardData }, cardsBefore)
        XCTAssertEqual(try context.count(for: DictationEventEntity.fetchRequest()), 12)
        let practice = try await repository.beginRemediation(dayID: day.id, now: now)
        XCTAssertEqual(practice.phase, .remediationCopy)
        let reopened = try await repository.loadOrCreateDay(limit: 3, now: now)
        XCTAssertEqual(reopened.phase, .remediationCopy)
        XCTAssertEqual(reopened.items, practice.items)
    }

    func testLoweringLimitPreservesPendingKeyboardVerification() async throws {
        let (_, repository, ids) = try regularLimitFixture(count: 15)
        let day = try await repository.loadOrCreateDay(limit: 0, now: now)
        for index in 0..<10 {
            _ = try await repository.submitFormal(dayID: day.id, wordID: ids[index],
                recognized: "word\(index)", now: now)
        }
        _ = try await repository.stageVerification(dayID: day.id, wordID: ids[10],
            recognized: "incorrect", now: now)
        let verification = try await repository.beginKeyboardVerification(dayID: day.id,
            wordID: ids[10], now: now)
        let limited = try await repository.loadOrCreateDay(limit: 10, now: now)
        XCTAssertEqual(limited.items.count, 11)
        XCTAssertEqual(limited.items.last, verification.items[10])
        XCTAssertEqual(limited.phase, .firstPass)
    }

    func testRaisingLimitDuringRemediationKeepsCopyProgressAndFirstResults() async throws {
        let (_, repository, ids) = try regularLimitFixture(count: 15)
        let day = try await repository.loadOrCreateDay(limit: 1, now: now)
        _ = try await repository.submitFormal(dayID: day.id, wordID: ids[0], recognized: "wrong", now: now)
        _ = try await repository.beginRemediation(dayID: day.id, now: now)
        let practice = try await repository.recordRemediationCopy(dayID: day.id,
            wordID: ids[0], recognized: "word0", now: now)
        let expanded = try await repository.loadOrCreateDay(limit: 10, now: now)
        XCTAssertEqual(expanded.items.count, 10)
        XCTAssertEqual(expanded.items.first, practice.items.first)
        XCTAssertEqual(expanded.firstPassAnswered, 1)
        XCTAssertEqual(expanded.unresolved, 1)
        XCTAssertEqual(expanded.phase, .firstPass)
    }

    func testLimitChangePreservesPreviousDayRemediationAndAppliesToBaselineDay() async throws {
        let (_, repository, ids) = try regularLimitFixture(count: 15)
        let day = try await repository.loadOrCreateDay(limit: 1, now: now)
        _ = try await repository.submitFormal(dayID: day.id, wordID: ids[0], recognized: "wrong", now: now)
        let practice = try await repository.beginRemediation(dayID: day.id, now: now)
        let nextDay = try await repository.loadOrCreateDay(limit: 10, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(nextDay.id, day.id)
        XCTAssertEqual(nextDay.limit, 1)
        XCTAssertEqual(nextDay.items, practice.items)

        let (controller, baselineRepository, baseline, _, campaign) = try await verificationFixture(wordCount: 2)
        let changed = try await baselineRepository.loadOrCreateDay(limit: 10, campaign: campaign, now: now)
        XCTAssertEqual(changed.items, baseline.items)
        XCTAssertEqual(changed.limit, 10)
        XCTAssertEqual(try controller.container.viewContext.count(for: DictationEventEntity.fetchRequest()), 0)
    }

    func testViewModelReadsLimitAtStartInsteadOfCachingInitializationValue() async throws {
        let instant = Date()
        let (controller, _, _) = try regularLimitFixture(count: 15, date: instant)
        let suite = "DictationLimitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.dictationLimit = .unlimited
        settings.baselineCampaign = BaselineCampaignSnapshot(selectedWordIDs: [], activatedAt: instant)
        let model = DictationViewModel(container: controller.container, settings: settings)
        settings.dictationLimit = .ten
        await model.start()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.day?.items.count, 10)
        settings.dictationLimit = .unlimited
        await model.start()
        XCTAssertEqual(model.day?.items.count, 15)
        settings.dictationLimit = .ten
        await model.start()
        XCTAssertEqual(model.day?.items.count, 10)
    }

    private func regularLimitFixture(count: Int, date: Date? = nil) throws
        -> (PersistenceController, DictationRepository, [UUID]) {
        let instant = date ?? now
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        var ids: [UUID] = []
        for index in 0..<count {
            let id = try seedBareWord("word\(index)", chinese: "词\(index)",
                at: instant.addingTimeInterval(-172_800 + Double(index)), in: context)
            let word = try XCTUnwrap(try context.fetch(WordEntity.fetchRequest()).first { $0.id == id })
            let state = DictationStateEntity(context: context)
            state.id = UUID()
            state.wordID = id
            state.word = word
            state.englishVersion = "word\(index)"
            state.initialCopyCount = 3
            state.initialCopyStartedAt = instant.addingTimeInterval(-86_400)
            state.initialCopyCompletedAt = instant.addingTimeInterval(-86_400)
            state.totalFormal = 1
            state.nextReviewDate = instant.addingTimeInterval(-86_400 + Double(index))
            state.fsrsCardData = try SRSScheduler.encodeCard(SRSScheduler.emptyCard(due: instant))
            ids.append(id)
        }
        try context.save()
        return (controller, DictationRepository(container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone)), ids)
    }

    private func verificationFixture(wordCount: Int = 1) async throws
        -> (PersistenceController, DictationRepository, DictationDay, [UUID], BaselineCampaignSnapshot) {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        var ids: [UUID] = []
        for index in 0..<wordCount {
            ids.append(try seedBareWord(index == 0 ? "gas" : "lamp", chinese: index == 0 ? "气体" : "灯",
                at: now.addingTimeInterval(-86_400 + Double(index)), in: context))
        }
        try context.save()
        let repo = DictationRepository(container: controller.container,
            calendar: DictationEligibility.calendar(timeZone: timezone))
        let campaign = try await repo.automaticBaselineCampaign(now: now)
        let day = try await repo.loadOrCreateDay(limit: 20, campaign: campaign, now: now)
        return (controller, repo, day, ids, campaign)
    }

    private func seedBareWord(
        _ english: String, chinese: String, at date: Date,
        in context: NSManagedObjectContext
    ) throws -> UUID {
        let word = WordEntity(context: context)
        word.id = UUID()
        word.english = english
        word.normalizedEnglish = english
        word.chinese = chinese
        word.importPosition = 0
        word.createdAt = date
        word.updatedAt = date
        for direction in ReviewDirection.allCases {
            let state = ReviewStateEntity(context: context)
            state.id = UUID()
            state.word = word
            state.direction = direction.rawValue
            state.level = 0
            state.nextReviewDate = date
            state.createdAt = date
            state.updatedAt = date
        }
        return word.id
    }

    private func cardEvent(
        at date: Date, result: ReviewResult,
        mode: PracticeMode = .scheduled, retry: Bool = false
    ) -> DictationCardEvent {
        DictationCardEvent(
            reviewedAt: date, direction: .chineseToEnglish, result: result,
            mode: mode, isSameSessionRetry: retry, englishSnapshot: "apple"
        )
    }

    private func seedEligibleWord(in context: NSManagedObjectContext) throws -> UUID {
        let word = WordEntity(context: context)
        word.id = UUID()
        word.english = "apple"
        word.normalizedEnglish = "apple"
        word.chinese = "苹果"
        word.importPosition = 0
        word.createdAt = now
        word.updatedAt = now

        let state = ReviewStateEntity(context: context)
        state.id = UUID()
        state.word = word
        state.direction = ReviewDirection.chineseToEnglish.rawValue
        state.level = 0
        state.nextReviewDate = now
        state.totalReviews = 2
        state.knownCount = 2
        state.unknownCount = 0
        state.consecutiveKnown = 2
        state.lapseCount = 0
        state.createdAt = now
        state.updatedAt = now

        let session = StudySessionEntity(context: context)
        session.id = UUID()
        session.mode = PracticeMode.scheduled.rawValue
        session.startedAt = now.addingTimeInterval(-172_800)
        session.completed = true
        session.baseTaskCount = 2
        session.formalAnswered = 2
        session.formalKnown = 2

        for daysAgo in [2.0, 1.0] {
            let event = ReviewEventEntity(context: context)
            event.id = UUID()
            event.word = word
            event.reviewState = state
            event.session = session
            event.sessionID = session.id
            event.reviewedAt = now.addingTimeInterval(-daysAgo * 86_400)
            event.direction = ReviewDirection.chineseToEnglish.rawValue
            event.result = ReviewResult.known.rawValue
            event.practiceMode = PracticeMode.scheduled.rawValue
            event.levelBefore = 0
            event.levelAfter = 0
            event.isSameSessionRetry = false
            event.wordEnglishSnapshot = "apple"
            event.wordChineseSnapshot = "苹果"
        }
        try context.save()
        return word.id
    }
}
