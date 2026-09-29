import CoreData
import Foundation

@objc(WordEntity)
final class WordEntity: NSManagedObject {}

extension WordEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<WordEntity> {
        NSFetchRequest<WordEntity>(entityName: "WordEntity")
    }

    @NSManaged var id: UUID
    @NSManaged var english: String
    @NSManaged var normalizedEnglish: String
    @NSManaged var importPosition: Int64
    @NSManaged var chinese: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var reviewStates: Set<ReviewStateEntity>
    @NSManaged var events: Set<ReviewEventEntity>
    @NSManaged var dictationState: DictationStateEntity?
}

@objc(DictationStateEntity)
final class DictationStateEntity: NSManagedObject {}

extension DictationStateEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DictationStateEntity> {
        NSFetchRequest<DictationStateEntity>(entityName: "DictationStateEntity")
    }

    @NSManaged var id: UUID
    @NSManaged var wordID: UUID
    @NSManaged var englishVersion: String
    @NSManaged var initialCopyCount: Int16
    @NSManaged var initialCopyStartedAt: Date
    @NSManaged var initialCopyCompletedAt: Date?
    @NSManaged var fsrsCardData: Data?
    @NSManaged var nextReviewDate: Date?
    @NSManaged var formalNotBefore: Date?
    @NSManaged var lastFormalDay: String?
    @NSManaged var totalFormal: Int64
    @NSManaged var lastResult: String?
    @NSManaged var word: WordEntity?
}

@objc(DictationDayEntity)
final class DictationDayEntity: NSManagedObject {}

extension DictationDayEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DictationDayEntity> {
        NSFetchRequest<DictationDayEntity>(entityName: "DictationDayEntity")
    }

    @NSManaged var id: UUID
    @NSManaged var dayKey: String
    @NSManaged var timeZoneID: String
    @NSManaged var limit: Int32
    @NSManaged var phase: String
    @NSManaged var tasksData: Data
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(DictationEventEntity)
final class DictationEventEntity: NSManagedObject {}

extension DictationEventEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DictationEventEntity> {
        NSFetchRequest<DictationEventEntity>(entityName: "DictationEventEntity")
    }

    @NSManaged var id: UUID
    @NSManaged var wordID: UUID
    @NSManaged var dayID: UUID?
    @NSManaged var dayKey: String
    @NSManaged var kind: String
    @NSManaged var formalKey: String?
    @NSManaged var result: String
    @NSManaged var reason: String?
    @NSManaged var recognizedText: String?
    @NSManaged var answerSnapshot: String
    @NSManaged var chineseSnapshot: String
    @NSManaged var submittedAt: Date
    @NSManaged var remainingSeconds: Double
    @NSManaged var round: Int16
    @NSManaged var fsrsBefore: Data?
    @NSManaged var fsrsAfter: Data?
}

@objc(ReviewStateEntity)
final class ReviewStateEntity: NSManagedObject {}

extension ReviewStateEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ReviewStateEntity> {
        NSFetchRequest<ReviewStateEntity>(entityName: "ReviewStateEntity")
    }

    @NSManaged var id: UUID
    @NSManaged var direction: String
    @NSManaged var level: Int16
    @NSManaged var nextReviewDate: Date
    @NSManaged var lastReviewDate: Date?
    @NSManaged var totalReviews: Int64
    @NSManaged var knownCount: Int64
    @NSManaged var unknownCount: Int64
    @NSManaged var consecutiveKnown: Int32
    @NSManaged var lapseCount: Int64
    @NSManaged var lastResult: String?
    @NSManaged var fsrsCardData: Data?
    @NSManaged var fsrsMigrationVersion: Int16
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var word: WordEntity?
    @NSManaged var events: Set<ReviewEventEntity>
}

@objc(ReviewEventEntity)
final class ReviewEventEntity: NSManagedObject {}

extension ReviewEventEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ReviewEventEntity> {
        NSFetchRequest<ReviewEventEntity>(entityName: "ReviewEventEntity")
    }

    @NSManaged var id: UUID
    @NSManaged var reviewedAt: Date
    @NSManaged var direction: String
    @NSManaged var result: String
    @NSManaged var practiceMode: String
    @NSManaged var levelBefore: Int16
    @NSManaged var levelAfter: Int16
    @NSManaged var isSameSessionRetry: Bool
    @NSManaged var sessionID: UUID
    @NSManaged var wordEnglishSnapshot: String
    @NSManaged var wordChineseSnapshot: String
    @NSManaged var word: WordEntity?
    @NSManaged var reviewState: ReviewStateEntity
    @NSManaged var session: StudySessionEntity
}

@objc(StudySessionEntity)
final class StudySessionEntity: NSManagedObject {}

extension StudySessionEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<StudySessionEntity> {
        NSFetchRequest<StudySessionEntity>(entityName: "StudySessionEntity")
    }

    @NSManaged var id: UUID
    @NSManaged var mode: String
    @NSManaged var startedAt: Date
    @NSManaged var finishedAt: Date?
    @NSManaged var completed: Bool
    @NSManaged var baseTaskCount: Int32
    @NSManaged var formalAnswered: Int32
    @NSManaged var formalKnown: Int32
    @NSManaged var formalUnknown: Int32
    @NSManaged var retryAnswered: Int32
    @NSManaged var extraAnswered: Int32
    @NSManaged var extraKnown: Int32
    @NSManaged var extraUnknown: Int32
    @NSManaged var events: Set<ReviewEventEntity>
}
