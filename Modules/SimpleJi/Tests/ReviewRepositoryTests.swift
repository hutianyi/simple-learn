import CoreData
import XCTest
@testable import WordMemoryCards

final class ReviewRepositoryTests: XCTestCase {
    @MainActor
    func testAnsweringOneDirectionDoesNotChangeTheOther() async throws {
        let fixture = try makeFixture()
        let repository = ReviewRepository(container: fixture.persistence.container)
        let sessionID = try await repository.startSession(mode: .scheduled, baseTaskCount: 1)

        _ = try await repository.recordAnswer(
            stateID: fixture.englishToChinese.id,
            sessionID: sessionID,
            mode: .scheduled,
            answer: .known,
            isSameSessionRetry: false
        )

        let context = fixture.persistence.container.viewContext
        context.refresh(fixture.englishToChinese, mergeChanges: true)
        context.refresh(fixture.chineseToEnglish, mergeChanges: true)
        XCTAssertEqual(fixture.englishToChinese.level, 5)
        XCTAssertEqual(fixture.chineseToEnglish.level, 2)
        XCTAssertNotEqual(
            fixture.englishToChinese.fsrsCardData,
            fixture.chineseToEnglish.fsrsCardData
        )
    }

    @MainActor
    func testSameSessionRetryDoesNotUpgradeOrMoveTomorrowDate() async throws {
        let fixture = try makeFixture()
        let repository = ReviewRepository(container: fixture.persistence.container)
        let sessionID = try await repository.startSession(mode: .scheduled, baseTaskCount: 1)

        _ = try await repository.recordAnswer(
            stateID: fixture.englishToChinese.id,
            sessionID: sessionID,
            mode: .scheduled,
            answer: .unknown,
            isSameSessionRetry: false
        )
        let context = fixture.persistence.container.viewContext
        context.refresh(fixture.englishToChinese, mergeChanges: true)
        let formalCardData = fixture.englishToChinese.fsrsCardData
        let formalDueDate = fixture.englishToChinese.nextReviewDate
        let retry = try await repository.recordAnswer(
            stateID: fixture.englishToChinese.id,
            sessionID: sessionID,
            mode: .scheduled,
            answer: .known,
            isSameSessionRetry: true
        )

        XCTAssertFalse(retry.changedFormalState)
        XCTAssertEqual(retry.levelAfter, 5)

        context.refresh(fixture.englishToChinese, mergeChanges: true)
        XCTAssertEqual(fixture.englishToChinese.level, 5)
        XCTAssertEqual(fixture.englishToChinese.fsrsCardData, formalCardData)
        XCTAssertEqual(fixture.englishToChinese.nextReviewDate, formalDueDate)
        XCTAssertEqual(fixture.englishToChinese.knownCount, 0)
        XCTAssertEqual(fixture.englishToChinese.unknownCount, 1)
    }

    @MainActor
    func testExtraPracticeCreatesEventsWithoutChangingSRS() async throws {
        let fixture = try makeFixture()
        let originalDate = fixture.englishToChinese.nextReviewDate
        let originalCardData = fixture.englishToChinese.fsrsCardData
        let repository = ReviewRepository(container: fixture.persistence.container)
        let sessionID = try await repository.startSession(mode: .extraPractice, baseTaskCount: 1)

        for answer in [ReviewResult.unknown, .unknown, .known, .known] {
            _ = try await repository.recordAnswer(
                stateID: fixture.englishToChinese.id,
                sessionID: sessionID,
                mode: .extraPractice,
                answer: answer,
                isSameSessionRetry: false
            )
        }

        let context = fixture.persistence.container.viewContext
        context.refresh(fixture.englishToChinese, mergeChanges: true)
        XCTAssertEqual(fixture.englishToChinese.level, 5)
        XCTAssertEqual(fixture.englishToChinese.nextReviewDate, originalDate)
        XCTAssertEqual(fixture.englishToChinese.fsrsCardData, originalCardData)
        XCTAssertEqual(fixture.englishToChinese.knownCount, 0)
        XCTAssertEqual(fixture.englishToChinese.unknownCount, 0)

        let request = ReviewEventEntity.fetchRequest()
        request.predicate = NSPredicate(format: "practiceMode == %@", PracticeMode.extraPractice.rawValue)
        XCTAssertEqual(try context.count(for: request), 4)
    }

    @MainActor
    func testInterruptedSessionKeepsAnsweredEvents() async throws {
        let fixture = try makeFixture()
        let repository = ReviewRepository(container: fixture.persistence.container)
        let sessionID = try await repository.startSession(mode: .scheduled, baseTaskCount: 30)
        _ = try await repository.recordAnswer(
            stateID: fixture.englishToChinese.id,
            sessionID: sessionID,
            mode: .scheduled,
            answer: .known,
            isSameSessionRetry: false
        )
        try await repository.finishSession(id: sessionID, completed: false)

        let context = fixture.persistence.container.viewContext
        let request = StudySessionEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", sessionID as NSUUID)
        let session = try XCTUnwrap(context.fetch(request).first)
        context.refresh(session, mergeChanges: true)
        XCTAssertFalse(session.completed)
        XCTAssertEqual(session.formalAnswered, 1)
        XCTAssertNotNil(session.finishedAt)
    }

    @MainActor
    private func makeFixture() throws -> (
        persistence: PersistenceController,
        englishToChinese: ReviewStateEntity,
        chineseToEnglish: ReviewStateEntity
    ) {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()
        let word = WordEntity(context: context)
        word.id = UUID()
        word.english = "apple"
        word.normalizedEnglish = "apple"
        word.chinese = "苹果"
        word.createdAt = now
        word.updatedAt = now

        let englishToChinese = makeState(
            direction: .englishToChinese,
            level: 5,
            word: word,
            context: context,
            now: now
        )
        let chineseToEnglish = makeState(
            direction: .chineseToEnglish,
            level: 2,
            word: word,
            context: context,
            now: now
        )
        try context.save()
        return (persistence, englishToChinese, chineseToEnglish)
    }

    private func makeState(
        direction: ReviewDirection,
        level: Int16,
        word: WordEntity,
        context: NSManagedObjectContext,
        now: Date
    ) -> ReviewStateEntity {
        let state = ReviewStateEntity(context: context)
        state.id = UUID()
        state.direction = direction.rawValue
        state.level = level
        state.nextReviewDate = now
        state.fsrsCardData = try! SRSScheduler.encodeCard(
            SRSScheduler.emptyCard(due: now)
        )
        state.fsrsMigrationVersion = SRSScheduler.migrationVersion
        state.createdAt = now
        state.updatedAt = now
        state.word = word
        return state
    }
}
