import Foundation
import SwiftData

enum PracticeService {
    static func activeSession(context: ModelContext) throws -> PracticeSession? {
        var descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate { $0.completedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func dueGroups(context: ModelContext, day: String = DayKey.make(from: .now)) throws -> [ProblemGroup] {
        let groups = try context.fetch(FetchDescriptor<ProblemGroup>())
        return groups.filter { group in
            guard !group.isArchived, let state = group.reviewState else { return false }
            switch state.status {
            case .new: return true
            case .scheduled: return state.nextReviewDay.map { $0 <= day } ?? true
            case .pendingCorrection, .needsExplanation, .mastered: return false
            }
        }.sorted { $0.createdAt < $1.createdAt }
    }

    static func makeDailySession(context: ModelContext, day: String = DayKey.make(from: .now)) throws -> PracticeSession? {
        if let active = try activeSession(context: context) { return active }
        let groups = try dueGroups(context: context, day: day)
        guard !groups.isEmpty else { return nil }
        let attempts = try context.fetch(FetchDescriptor<Attempt>())
        let lastShown = latestPresentationByQuestion(attempts)

        let session = PracticeSession(mode: .daily, dayKey: day)
        context.insert(session)
        for (index, group) in groups.enumerated() {
            guard let question = chooseQuestion(for: group, lastShown: lastShown) else { continue }
            let state = group.reviewState
            let attempt = Attempt(
                orderIndex: index,
                context: state?.creditedCorrectCount == 0 ? .initial : .scheduled,
                eligibleForCredit: true
            )
            attempt.group = group
            attempt.question = question
            session.attempts.append(attempt)
            context.insert(attempt)
        }
        guard !session.attempts.isEmpty else {
            context.delete(session)
            return nil
        }
        try context.save()
        return session
    }

    static func makeCorrectionSession(for group: ProblemGroup, context: ModelContext, day: String = DayKey.make(from: .now)) throws -> PracticeSession {
        if let active = try activeSession(context: context) { return active }
        let session = PracticeSession(phase: .correction, mode: .targetedCorrection, dayKey: day)
        let progress = SessionGroupProgress()
        progress.group = group
        session.groupProgress.append(progress)
        context.insert(session)
        context.insert(progress)
        try context.save()
        return session
    }

    static func markPresented(_ attempt: Attempt, context: ModelContext) {
        guard attempt.presentedAt == nil else { return }
        attempt.presentedAt = .now
        try? context.save()
    }

    static func commitMarking(session: PracticeSession, context: ModelContext, now: Date = .now) throws {
        let day = DayKey.make(from: now)
        let initial = session.attempts.filter { $0.context != .correction }.sorted { $0.orderIndex < $1.orderIndex }
        guard !initial.isEmpty, initial.allSatisfy({ $0.draftResult != nil }) else { throw PracticeFailure.incompleteMarking }
        var wrongGroups: [ProblemGroup] = []

        for attempt in initial where attempt.result == nil {
            guard let draft = attempt.draftResult, let group = attempt.group, let state = group.reviewState else { continue }
            attempt.result = draft
            attempt.committedAt = now
            switch draft {
            case .correct where attempt.eligibleForCredit:
                state.apply(ReviewScheduler.apply(.formalCorrect(day: day), to: state.snapshot))
            case .wrong:
                state.apply(ReviewScheduler.apply(.formalWrong(day: day), to: state.snapshot))
                wrongGroups.append(group)
            case .excluded:
                attempt.question?.disabledAt = .now
                attempt.question?.disabledReason = "练习时标记题目有问题"
            default:
                break
            }
        }

        for group in wrongGroups where !session.groupProgress.contains(where: { $0.group?.id == group.id }) {
            let progress = SessionGroupProgress()
            progress.group = group
            session.groupProgress.append(progress)
            context.insert(progress)
        }
        session.phase = wrongGroups.isEmpty ? .summary : .correction
        try context.save()
    }

    static func makeCorrectionAttempt(for progress: SessionGroupProgress, context: ModelContext) throws -> Attempt? {
        guard let session = progress.session, let group = progress.group else { return nil }
        let usedIDs = Set(session.attempts.compactMap { $0.question?.id })
        let allAttempts = try context.fetch(FetchDescriptor<Attempt>())
        let lastShown = latestPresentationByQuestion(allAttempts)
        let candidates = group.questions.compactMap { question -> SelectionCandidate? in
            guard question.kind == .near else { return nil }
            return .init(id: question.id, kind: .near, disabled: question.disabledAt != nil, lastPresentedAt: lastShown[question.id])
        }
        guard let selected = QuestionSelector.choose(from: candidates, creditedCorrectCount: 0, excluding: usedIDs),
              let question = group.questions.first(where: { $0.id == selected.id }) else {
            progress.stage = .materialShortage
            try context.save()
            return nil
        }
        let attempt = Attempt(orderIndex: session.attempts.count, context: .correction, eligibleForCredit: false)
        attempt.group = group
        attempt.question = question
        session.attempts.append(attempt)
        context.insert(attempt)
        progress.stage = .pendingFollowup
        try context.save()
        return attempt
    }

    static func gradeCorrection(_ result: AttemptResult, progress: SessionGroupProgress, context: ModelContext, now: Date = .now) throws {
        guard let session = progress.session, let group = progress.group, let state = group.reviewState,
              let attempt = session.attempts.filter({ $0.context == .correction && $0.group?.id == group.id && $0.result == nil }).max(by: { $0.orderIndex < $1.orderIndex }) else { return }
        attempt.result = result
        attempt.committedAt = now
        switch result {
        case .correct:
            state.apply(ReviewScheduler.apply(.correctionSucceeded(day: DayKey.make(from: now)), to: state.snapshot))
            progress.stage = .passed
        case .wrong:
            progress.correctionFailureCount += 1
            if progress.correctionFailureCount >= 3 {
                state.apply(ReviewScheduler.apply(.explanationNeeded, to: state.snapshot))
                progress.stage = .needsExplanation
            } else {
                progress.stage = .pendingReview
            }
        case .excluded:
            attempt.question?.disabledAt = .now
            attempt.question?.disabledReason = "订正时标记题目有问题"
            progress.stage = .pendingReview
        }
        if session.groupProgress.allSatisfy({ [.passed, .needsExplanation, .materialShortage].contains($0.stage) }) {
            session.phase = .summary
        }
        try context.save()
    }

    static func complete(_ session: PracticeSession, context: ModelContext) throws {
        session.phase = .completed
        session.completedAt = .now
        try context.save()
    }

    private static func latestPresentationByQuestion(_ attempts: [Attempt]) -> [UUID: Date] {
        attempts.reduce(into: [:]) { result, attempt in
            guard let id = attempt.question?.id, let date = attempt.presentedAt else { return }
            if result[id].map({ $0 < date }) ?? true { result[id] = date }
        }
    }

    private static func chooseQuestion(for group: ProblemGroup, lastShown: [UUID: Date]) -> Question? {
        let count = group.reviewState?.creditedCorrectCount ?? 0
        let candidates = group.questions.compactMap { question -> SelectionCandidate? in
            guard question.kind != .original else { return nil }
            return .init(id: question.id, kind: question.kind == .near ? .near : .transfer, disabled: question.disabledAt != nil, lastPresentedAt: lastShown[question.id])
        }
        guard let selected = QuestionSelector.choose(from: candidates, creditedCorrectCount: count) else { return nil }
        return group.questions.first { $0.id == selected.id }
    }
}

enum PracticeFailure: LocalizedError {
    case incompleteMarking
    var errorDescription: String? { "还有题目没有判定结果。" }
}
