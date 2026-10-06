import CoreData
import Foundation

final class StudyCompletionRepository {
    private let container: NSPersistentContainer
    private let calendar: Calendar

    init(container: NSPersistentContainer, calendar: Calendar = .current) {
        self.container = container
        self.calendar = calendar
    }

    func refresh(scope: StudyCompletionScope, now: Date = Date()) async throws {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        let calendar = self.calendar
        try await context.perform {
            try Self.refresh(in: context, now: now, calendar: calendar, scope: scope)
            if context.hasChanges { try context.save() }
        }
    }

    // Capture all due cards, including any omitted from a single session's queue.
    // Call before rating a card so advancing its due date cannot hide unfinished work.
    static func refresh(in context: NSManagedObjectContext, now: Date,
                        calendar: Calendar = .current, scope: StudyCompletionScope? = nil) throws {
        let key = DictationEligibility.dayKey(for: now, calendar: calendar)
        let start = calendar.startOfDay(for: now)
        let tomorrow = DictationEligibility.nextDay(after: now, calendar: calendar)
        let request = StudyCompletionDayEntity.fetchRequest()
        request.predicate = NSPredicate(format: "dayKey == %@", key)
        let existing = try context.fetch(request).first
        let entity = existing ?? StudyCompletionDayEntity(context: context)
        let previous = try existing.map { try JSONDecoder().decode(StudyCompletionDay.self, from: $0.snapshotData) }
        var day = previous ?? StudyCompletionDay(dayKey: key, timeZoneID: calendar.timeZone.identifier)
        if let scope { day.scope = scope }

        let cards = try context.fetch(ReviewStateEntity.fetchRequest())
        let events = try context.fetch(ReviewEventEntity.fetchRequest()).filter {
            $0.reviewedAt >= start && $0.reviewedAt <= now
        }
        day.answeredCardIDs = Set(events.filter {
            $0.practiceMode == PracticeMode.scheduled.rawValue && !$0.isSameSessionRetry
        }.map { $0.reviewState.id })
        day.requiredCardIDs.formUnion(cards.filter {
            $0.nextReviewDate < tomorrow && !day.answeredCardIDs.contains($0.id)
        }.map(\.id))
        day.requiredCardIDs.formUnion(day.answeredCardIDs)
        day.requiredCardIDs.formIntersection(Set(cards.map(\.id)))

        let allDictationDays = try context.fetch(DictationDayEntity.fetchRequest())
        let dictationDays = allDictationDays.filter { $0.dayKey <= key && !$0.dayKey.hasSuffix("#repair") }
        let unfinished = try dictationDays.contains { entity in
            let items = try JSONDecoder().decode([DictationItem].self, from: entity.tasksData)
            return !StudyStreak.dictationFinished(phase: entity.phase, items: items)
        }
        let words = try context.fetch(WordEntity.fetchRequest()).filter {
            !day.scope.masteredTerms.contains(EnglishNormalizer.normalize($0.english))
        }
        // A finished daily queue may still leave overdue words outside its limit.
        // Today's excess is deferred; previous days' eligible debt blocks completion.
        let pendingRegularWords = words.filter { word in
            guard let state = word.dictationState else { return false }
            return state.englishVersion == DictationAnswerMatcher.normalize(word.english)
                && (state.initialCopyCompletedAt != nil || state.totalFormal > 0)
                && (state.nextReviewDate.map { $0 < tomorrow } ?? false)
                && (state.formalNotBefore ?? .distantPast) <= now && state.lastFormalDay != key
        }
        let overduePending = pendingRegularWords.contains {
            ($0.dictationState?.nextReviewDate ?? .distantFuture) < start
        }
        if unfinished || overduePending {
            day.dictationComplete = false
        } else if dictationDays.contains(where: { $0.dayKey == key }) {
            day.dictationComplete = true
        } else {
            let dictationEvents = try context.fetch(DictationEventEntity.fetchRequest())
            let tested = Set(dictationEvents.filter { $0.kind == "baselineFormal" }.map(\.wordID))
            let baselinePending = words.contains { word in
                let selected = day.scope.baselineWordIDs?.contains(word.id) ?? (word.createdAt < start)
                return selected && !tested.contains(word.id) && (word.dictationState?.totalFormal ?? 0) == 0
            }
            day.dictationComplete = !baselinePending && pendingRegularWords.isEmpty
        }
        let dictationEvents = try context.fetch(DictationEventEntity.fetchRequest())
        day.hasActivity = !events.isEmpty || dictationEvents.contains {
            $0.submittedAt >= start && $0.submittedAt <= now
                && ($0.result == "correct" || $0.result == "incorrect")
        }
        if var repair = day.repair, repair.status == .accepted {
            if let id = repair.dictationDayID, let entity = allDictationDays.first(where: { $0.id == id }) {
                let items = try JSONDecoder().decode([DictationItem].self, from: entity.tasksData)
                repair.dictationComplete = StudyStreak.dictationFinished(phase: entity.phase, items: items)
            }
            if day.normalTasksComplete && repair.cardsComplete && repair.dictationComplete {
                repair.status = .completed
                repair.restoredAt = now
            }
            day.repair = repair
        }
        day.completedAt = day.isComplete ? (day.completedAt ?? now) : nil
        guard day != previous else { return }
        entity.dayKey = key
        entity.snapshotData = try JSONEncoder().encode(day)
    }
}
