import CoreData
import Foundation
import FSRS

enum FSRSMigrationService {
    struct MigrationResult: Equatable {
        let migratedStates: Int
        let replayedEvents: Int
    }

    static func migrateAll(
        in context: NSManagedObjectContext,
        now: Date = Date()
    ) throws -> MigrationResult {
        let request = ReviewStateEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "fsrsMigrationVersion < %d OR fsrsCardData == nil",
            SRSScheduler.migrationVersion
        )
        request.relationshipKeyPathsForPrefetching = ["events"]

        var migratedStates = 0
        var replayedEvents = 0
        for state in try context.fetch(request) {
            replayedEvents += try migrate(state, now: now)
            migratedStates += 1
        }
        if context.hasChanges { try context.save() }
        return MigrationResult(
            migratedStates: migratedStates,
            replayedEvents: replayedEvents
        )
    }

    @discardableResult
    static func migrate(_ state: ReviewStateEntity, now: Date = Date()) throws -> Int {
        guard state.fsrsMigrationVersion < SRSScheduler.migrationVersion
                || state.fsrsCardData == nil else { return 0 }

        let formalEvents = state.events
            .filter {
                $0.practiceMode == PracticeMode.scheduled.rawValue
                    && !$0.isSameSessionRetry
                    && $0.direction == state.direction
                    && ReviewResult(rawValue: $0.result) != nil
            }
            .sorted {
                if $0.reviewedAt != $1.reviewedAt { return $0.reviewedAt < $1.reviewedAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        var card = SRSScheduler.emptyCard(due: formalEvents.first?.reviewedAt ?? now)
        for event in formalEvents {
            guard let answer = ReviewResult(rawValue: event.result) else { continue }
            let decision = try SRSScheduler.decision(
                card: card,
                answer: answer,
                date: event.reviewedAt
            )
            card = try SRSScheduler.decodeCard(decision.cardData)
        }

        state.fsrsCardData = try SRSScheduler.encodeCard(card)
        state.fsrsMigrationVersion = SRSScheduler.migrationVersion
        state.nextReviewDate = card.due
        state.updatedAt = max(state.updatedAt, formalEvents.last?.reviewedAt ?? now)
        return formalEvents.count
    }
}
