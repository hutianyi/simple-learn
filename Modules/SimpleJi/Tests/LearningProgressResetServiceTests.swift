import CoreData
import XCTest
@testable import WordMemoryCards

@MainActor
final class LearningProgressResetServiceTests: XCTestCase {
    func testResetPreservesWordsAndResetsBothDirections() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let now = Date()

        let word = WordEntity(context: context)
        word.id = UUID()
        word.english = "apple"
        word.normalizedEnglish = "apple"
        word.chinese = "苹果"
        word.createdAt = now
        word.updatedAt = now

        var states: [ReviewStateEntity] = []
        for direction in ReviewDirection.allCases {
            let state = ReviewStateEntity(context: context)
            state.id = UUID()
            state.word = word
            state.direction = direction.rawValue
            state.level = 5
            state.nextReviewDate = now.addingTimeInterval(86_400 * 30)
            state.lastReviewDate = now
            state.totalReviews = 8
            state.knownCount = 6
            state.unknownCount = 2
            state.consecutiveKnown = 3
            state.lapseCount = 2
            state.lastResult = ReviewResult.known.rawValue
            state.createdAt = now
            state.updatedAt = now
            states.append(state)
        }

        let session = StudySessionEntity(context: context)
        session.id = UUID()
        session.mode = PracticeMode.scheduled.rawValue
        session.startedAt = now
        session.completed = true
        session.baseTaskCount = 1
        session.formalAnswered = 1

        let event = ReviewEventEntity(context: context)
        event.id = UUID()
        event.word = word
        event.reviewState = states[0]
        event.session = session
        event.sessionID = session.id
        event.reviewedAt = now
        event.direction = states[0].direction
        event.result = ReviewResult.known.rawValue
        event.practiceMode = PracticeMode.scheduled.rawValue
        event.levelBefore = 4
        event.levelAfter = 5
        event.isSameSessionRetry = false
        event.wordEnglishSnapshot = word.english
        event.wordChineseSnapshot = word.chinese
        let dictation = DictationStateEntity(context: context)
        dictation.id = UUID()
        dictation.wordID = word.id
        dictation.word = word
        dictation.englishVersion = "apple"
        dictation.initialCopyCount = 3
        dictation.initialCopyStartedAt = now
        dictation.initialCopyCompletedAt = now
        dictation.totalFormal = 1
        let day = DictationDayEntity(context: context)
        day.id = UUID()
        day.dayKey = "2026-09-27"
        day.timeZoneID = "Asia/Shanghai"
        day.limit = 20
        day.phase = DictationPhase.complete.rawValue
        day.tasksData = try JSONEncoder().encode([
            DictationItem(wordID: word.id, english: "apple", chinese: "苹果")
        ])
        day.createdAt = now
        day.updatedAt = now
        let dictationEvent = DictationEventEntity(context: context)
        dictationEvent.id = UUID()
        dictationEvent.wordID = word.id
        dictationEvent.dayID = day.id
        dictationEvent.dayKey = day.dayKey
        dictationEvent.kind = "formal"
        dictationEvent.result = "correct"
        dictationEvent.answerSnapshot = "apple"
        dictationEvent.chineseSnapshot = "苹果"
        dictationEvent.submittedAt = now
        dictationEvent.remainingSeconds = 12
        dictationEvent.round = 0
        try context.save()

        try await LearningProgressResetService.reset(
            container: controller.container,
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )
        context.reset()

        XCTAssertEqual(try context.count(for: WordEntity.fetchRequest()), 1)
        XCTAssertEqual(try context.count(for: ReviewEventEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: StudySessionEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: DictationStateEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: DictationDayEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: DictationEventEntity.fetchRequest()), 0)

        let resetStates = try context.fetch(ReviewStateEntity.fetchRequest())
        XCTAssertEqual(resetStates.count, 2)
        for state in resetStates {
            XCTAssertEqual(state.level, 0)
            XCTAssertEqual(state.totalReviews, 0)
            XCTAssertEqual(state.knownCount, 0)
            XCTAssertEqual(state.unknownCount, 0)
            XCTAssertEqual(state.consecutiveKnown, 0)
            XCTAssertEqual(state.lapseCount, 0)
            XCTAssertNil(state.lastReviewDate)
            XCTAssertNil(state.lastResult)
            let card = try SRSScheduler.decodeCard(XCTUnwrap(state.fsrsCardData))
            XCTAssertEqual(state.fsrsMigrationVersion, SRSScheduler.migrationVersion)
            XCTAssertEqual(card.reps, 0)
        }
    }
}
