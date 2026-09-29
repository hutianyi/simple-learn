import CoreData
import Foundation

struct RecordedAnswer: Equatable {
    let levelBefore: Int
    let levelAfter: Int
    let nextReviewDate: Date
    let changedFormalState: Bool
}

final class ReviewRepository {
    enum RepositoryError: LocalizedError {
        case stateNotFound
        case sessionNotFound
        case invalidRelationship
        case invalidDirection

        var errorDescription: String? {
            switch self {
            case .stateNotFound: return "找不到这张复习卡。"
            case .sessionNotFound: return "找不到当前学习 Session。"
            case .invalidRelationship: return "复习卡与单词的关联已损坏。"
            case .invalidDirection: return "复习方向数据无效。"
            }
        }
    }

    private let container: NSPersistentContainer
    private let calendar: Calendar

    init(container: NSPersistentContainer, calendar: Calendar = .current) {
        self.container = container
        self.calendar = calendar
    }

    func dueStates(today: Date = Date()) async throws -> [ReviewStateSnapshot] {
        let startOfToday = calendar.startOfDay(for: today)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? today
        let context = container.newBackgroundContext()
        context.undoManager = nil

        return try await context.perform {
            _ = try FSRSMigrationService.migrateAll(in: context, now: today)
            let request = ReviewStateEntity.fetchRequest()
            request.predicate = NSPredicate(format: "nextReviewDate < %@", tomorrow as NSDate)
            request.relationshipKeyPathsForPrefetching = ["word"]
            return try context.fetch(request).map { try Self.snapshot($0) }
        }
    }

    func weakStates() async throws -> [ReviewStateSnapshot] {
        let context = container.newBackgroundContext()
        context.undoManager = nil

        return try await context.perform {
            _ = try FSRSMigrationService.migrateAll(in: context)
            let request = ReviewStateEntity.fetchRequest()
            request.predicate = NSPredicate(format: "unknownCount > 0")
            request.relationshipKeyPathsForPrefetching = ["word", "events"]
            return try context.fetch(request).map {
                try Self.snapshot($0, includeExtraAttempts: true)
            }
        }
    }

    func allStates() async throws -> [ReviewStateSnapshot] {
        let context = container.newBackgroundContext()
        context.undoManager = nil

        return try await context.perform {
            _ = try FSRSMigrationService.migrateAll(in: context)
            let request = ReviewStateEntity.fetchRequest()
            request.relationshipKeyPathsForPrefetching = ["word", "events"]
            return try context.fetch(request).map {
                try Self.snapshot($0, includeExtraAttempts: true)
            }
        }
    }

    func startSession(
        mode: PracticeMode,
        baseTaskCount: Int,
        startedAt: Date = Date()
    ) async throws -> UUID {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        return try await context.perform {
            let session = StudySessionEntity(context: context)
            session.id = UUID()
            session.mode = mode.rawValue
            session.startedAt = startedAt
            session.completed = false
            session.baseTaskCount = Int32(baseTaskCount)
            try context.save()
            return session.id
        }
    }

    func recordAnswer(
        stateID: UUID,
        sessionID: UUID,
        mode: PracticeMode,
        answer: ReviewResult,
        isSameSessionRetry: Bool,
        reviewedAt: Date = Date()
    ) async throws -> RecordedAnswer {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        return try await context.perform {
            do {
                let state = try Self.fetchState(id: stateID, in: context)
                let session = try Self.fetchSession(id: sessionID, in: context)
                guard let word = state.word else { throw RepositoryError.invalidRelationship }
                guard ReviewDirection(rawValue: state.direction) != nil else {
                    throw RepositoryError.invalidDirection
                }

                let levelBefore = Int(state.level)
                let levelAfter = levelBefore
                var nextReviewDate = state.nextReviewDate
                let changesFormalState = mode == .scheduled && !isSameSessionRetry

                if changesFormalState {
                    _ = try FSRSMigrationService.migrate(state, now: reviewedAt)
                    let decision = try SRSScheduler.decision(
                        cardData: state.fsrsCardData,
                        answer: answer,
                        date: reviewedAt
                    )
                    nextReviewDate = decision.nextReviewDate

                    state.fsrsCardData = decision.cardData
                    state.fsrsMigrationVersion = SRSScheduler.migrationVersion
                    state.nextReviewDate = nextReviewDate
                    state.lastReviewDate = reviewedAt
                    state.totalReviews += 1
                    state.lastResult = answer.rawValue
                    state.updatedAt = reviewedAt

                    switch answer {
                    case .known:
                        state.knownCount += 1
                        state.consecutiveKnown += 1
                    case .unknown:
                        state.unknownCount += 1
                        state.consecutiveKnown = 0
                        state.lapseCount += 1
                    }
                }

                let event = ReviewEventEntity(context: context)
                event.id = UUID()
                event.reviewedAt = reviewedAt
                event.direction = state.direction
                event.result = answer.rawValue
                event.practiceMode = mode.rawValue
                event.levelBefore = Int16(levelBefore)
                event.levelAfter = Int16(levelAfter)
                event.isSameSessionRetry = isSameSessionRetry
                event.sessionID = sessionID
                event.wordEnglishSnapshot = word.english
                event.wordChineseSnapshot = word.chinese
                event.word = word
                event.reviewState = state
                event.session = session

                switch mode {
                case .scheduled:
                    if isSameSessionRetry {
                        session.retryAnswered += 1
                    } else {
                        session.formalAnswered += 1
                        if answer == .known {
                            session.formalKnown += 1
                        } else {
                            session.formalUnknown += 1
                        }
                    }
                case .extraPractice:
                    session.extraAnswered += 1
                    if answer == .known {
                        session.extraKnown += 1
                    } else {
                        session.extraUnknown += 1
                    }
                }

                try context.save()
                return RecordedAnswer(
                    levelBefore: levelBefore,
                    levelAfter: levelAfter,
                    nextReviewDate: nextReviewDate,
                    changedFormalState: changesFormalState
                )
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func finishSession(
        id: UUID,
        completed: Bool,
        finishedAt: Date = Date()
    ) async throws {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil

        try await context.perform {
            let session = try Self.fetchSession(id: id, in: context)
            session.completed = completed
            session.finishedAt = finishedAt
            try context.save()
        }
    }

    func discardSessionIfEmpty(id: UUID) async throws {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil

        try await context.perform {
            let session = try Self.fetchSession(id: id, in: context)
            guard session.formalAnswered == 0,
                  session.retryAnswered == 0,
                  session.extraAnswered == 0 else { return }
            context.delete(session)
            try context.save()
        }
    }

    private static func snapshot(
        _ state: ReviewStateEntity,
        includeExtraAttempts: Bool = false
    ) throws -> ReviewStateSnapshot {
        guard let word = state.word else { throw RepositoryError.invalidRelationship }
        guard let direction = ReviewDirection(rawValue: state.direction) else {
            throw RepositoryError.invalidDirection
        }

        let extraAttempts = includeExtraAttempts
            ? state.events.reduce(into: 0) { count, event in
                if event.practiceMode == PracticeMode.extraPractice.rawValue { count += 1 }
            }
            : 0

        return ReviewStateSnapshot(
            id: state.id,
            wordID: word.id,
            english: word.english,
            normalizedEnglish: word.normalizedEnglish,
            chinese: word.chinese,
            direction: direction,
            level: Int(state.level),
            nextReviewDate: state.nextReviewDate,
            formalKnownCount: Int(state.knownCount),
            formalUnknownCount: Int(state.unknownCount),
            consecutiveKnown: Int(state.consecutiveKnown),
            lastFormalResult: state.lastResult.flatMap(ReviewResult.init(rawValue:)),
            extraPracticeAttempts: extraAttempts
        )
    }

    private static func fetchState(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> ReviewStateEntity {
        let request = ReviewStateEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        guard let state = try context.fetch(request).first else {
            throw RepositoryError.stateNotFound
        }
        return state
    }

    private static func fetchSession(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> StudySessionEntity {
        let request = StudySessionEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        guard let session = try context.fetch(request).first else {
            throw RepositoryError.sessionNotFound
        }
        return session
    }
}
