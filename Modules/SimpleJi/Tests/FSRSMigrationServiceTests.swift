import CoreData
import XCTest
@testable import WordMemoryCards

@MainActor
final class FSRSMigrationServiceTests: XCTestCase {
    func testMigrationReplaysOnlyFormalFirstAnswersAndDoesNotRepeat() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let start = Date(timeIntervalSince1970: 1_788_192_000)
        let state = try makeState(in: context, now: start)
        let session = makeSession(in: context, now: start)

        makeEvent(state: state, session: session, result: .known, mode: .scheduled, retry: false, at: start)
        makeEvent(state: state, session: session, result: .unknown, mode: .scheduled, retry: true, at: start.addingTimeInterval(60))
        makeEvent(state: state, session: session, result: .unknown, mode: .extraPractice, retry: false, at: start.addingTimeInterval(120))
        makeEvent(state: state, session: session, result: .known, mode: .scheduled, retry: false, at: start.addingTimeInterval(86_400 * 3))
        try context.save()

        let first = try FSRSMigrationService.migrateAll(in: context, now: start)
        let firstData = try XCTUnwrap(state.fsrsCardData)
        let firstDue = state.nextReviewDate
        let card = try SRSScheduler.decodeCard(firstData)
        let second = try FSRSMigrationService.migrateAll(in: context, now: start.addingTimeInterval(999))

        XCTAssertEqual(first, .init(migratedStates: 1, replayedEvents: 2))
        XCTAssertEqual(card.reps, 2)
        XCTAssertEqual(second, .init(migratedStates: 0, replayedEvents: 0))
        XCTAssertEqual(state.fsrsCardData, firstData)
        XCTAssertEqual(state.nextReviewDate, firstDue)
    }

    func testStateWithoutHistoryBecomesSafeNewCard() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let now = Date(timeIntervalSince1970: 1_788_192_000)
        let state = try makeState(in: context, now: now)
        try context.save()

        let result = try FSRSMigrationService.migrateAll(in: context, now: now)
        let card = try SRSScheduler.decodeCard(XCTUnwrap(state.fsrsCardData))

        XCTAssertEqual(result.replayedEvents, 0)
        XCTAssertEqual(card.state.rawValue, 0)
        XCTAssertEqual(card.reps, 0)
        XCTAssertEqual(card.due, now)
    }

    private func makeState(
        in context: NSManagedObjectContext,
        now: Date
    ) throws -> ReviewStateEntity {
        let word = WordEntity(context: context)
        word.id = UUID()
        word.english = "apple"
        word.normalizedEnglish = "apple-\(UUID().uuidString)"
        word.chinese = "苹果"
        word.createdAt = now
        word.updatedAt = now

        let state = ReviewStateEntity(context: context)
        state.id = UUID()
        state.word = word
        state.direction = ReviewDirection.englishToChinese.rawValue
        state.level = 7
        state.nextReviewDate = now
        state.fsrsMigrationVersion = 0
        state.createdAt = now
        state.updatedAt = now
        return state
    }

    private func makeSession(
        in context: NSManagedObjectContext,
        now: Date
    ) -> StudySessionEntity {
        let session = StudySessionEntity(context: context)
        session.id = UUID()
        session.mode = PracticeMode.scheduled.rawValue
        session.startedAt = now
        session.completed = true
        return session
    }

    @discardableResult
    private func makeEvent(
        state: ReviewStateEntity,
        session: StudySessionEntity,
        result: ReviewResult,
        mode: PracticeMode,
        retry: Bool,
        at date: Date
    ) -> ReviewEventEntity {
        let event = ReviewEventEntity(context: state.managedObjectContext!)
        event.id = UUID()
        event.word = state.word
        event.reviewState = state
        event.session = session
        event.sessionID = session.id
        event.reviewedAt = date
        event.direction = state.direction
        event.result = result.rawValue
        event.practiceMode = mode.rawValue
        event.isSameSessionRetry = retry
        event.wordEnglishSnapshot = state.word?.english ?? ""
        event.wordChineseSnapshot = state.word?.chinese ?? ""
        return event
    }
}
