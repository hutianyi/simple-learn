import CoreData
import Foundation

enum LearningProgressResetService {
    static func reset(
        container: NSPersistentContainer,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        let dueDate = calendar.startOfDay(for: now)

        try await context.perform {
            do {
                for day in try context.fetch(StudyCompletionDayEntity.fetchRequest()) { context.delete(day) }
                for event in try context.fetch(DictationEventEntity.fetchRequest()) {
                    context.delete(event)
                }
                for day in try context.fetch(DictationDayEntity.fetchRequest()) {
                    context.delete(day)
                }
                for state in try context.fetch(DictationStateEntity.fetchRequest()) {
                    context.delete(state)
                }
                for event in try context.fetch(ReviewEventEntity.fetchRequest()) {
                    context.delete(event)
                }
                for session in try context.fetch(StudySessionEntity.fetchRequest()) {
                    context.delete(session)
                }
                for state in try context.fetch(ReviewStateEntity.fetchRequest()) {
                    state.level = 0
                    state.nextReviewDate = dueDate
                    state.fsrsCardData = try SRSScheduler.encodeCard(
                        SRSScheduler.emptyCard(due: dueDate)
                    )
                    state.fsrsMigrationVersion = SRSScheduler.migrationVersion
                    state.lastReviewDate = nil
                    state.totalReviews = 0
                    state.knownCount = 0
                    state.unknownCount = 0
                    state.consecutiveKnown = 0
                    state.lapseCount = 0
                    state.lastResult = nil
                    state.updatedAt = now
                }
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }
}
