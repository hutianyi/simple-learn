import Foundation
import SwiftData

@Model
final class ImportBatch {
    @Attribute(.unique) var id: UUID
    var title: String
    var sourceNote: String?
    var importedAt: Date
    var schemaVersion: Int
    var payloadHash: String
    @Relationship(deleteRule: .cascade, inverse: \ProblemGroup.batch) var groups: [ProblemGroup] = []

    init(id: UUID = UUID(), title: String, sourceNote: String?, importedAt: Date = .now, schemaVersion: Int, payloadHash: String) {
        self.id = id
        self.title = title
        self.sourceNote = sourceNote
        self.importedAt = importedAt
        self.schemaVersion = schemaVersion
        self.payloadHash = payloadHash
    }
}

@Model
final class ProblemGroup {
    @Attribute(.unique) var id: UUID
    var externalID: String
    var title: String
    var createdAt: Date
    var isArchived: Bool
    var batch: ImportBatch?
    @Relationship(deleteRule: .cascade, inverse: \Question.group) var questions: [Question] = []
    @Relationship(deleteRule: .cascade, inverse: \ReviewState.group) var reviewState: ReviewState?

    init(id: UUID = UUID(), externalID: String, title: String, createdAt: Date = .now, isArchived: Bool = false) {
        self.id = id
        self.externalID = externalID
        self.title = title
        self.createdAt = createdAt
        self.isArchived = isArchived
    }
}

@Model
final class Question {
    @Attribute(.unique) var id: UUID
    var externalID: String
    var kindRaw: String
    var promptMarkdown: String
    var answerMarkdown: String
    var explanationMarkdown: String
    var createdAt: Date
    var disabledAt: Date?
    var disabledReason: String?
    var group: ProblemGroup?

    var kind: QuestionKind {
        get { QuestionKind(rawValue: kindRaw) ?? .near }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), externalID: String, kind: QuestionKind, promptMarkdown: String, answerMarkdown: String, explanationMarkdown: String, createdAt: Date = .now) {
        self.id = id
        self.externalID = externalID
        self.kindRaw = kind.rawValue
        self.promptMarkdown = promptMarkdown
        self.answerMarkdown = answerMarkdown
        self.explanationMarkdown = explanationMarkdown
        self.createdAt = createdAt
    }
}

@Model
final class ReviewState {
    @Attribute(.unique) var id: UUID
    var statusRaw: String
    var creditedCorrectCount: Int
    var nextReviewDay: String?
    var lastCreditedDay: String?
    var updatedAt: Date
    var group: ProblemGroup?

    var status: ReviewStatus {
        get { ReviewStatus(rawValue: statusRaw) ?? .new }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), status: ReviewStatus = .new, creditedCorrectCount: Int = 0, nextReviewDay: String? = nil, lastCreditedDay: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.statusRaw = status.rawValue
        self.creditedCorrectCount = creditedCorrectCount
        self.nextReviewDay = nextReviewDay
        self.lastCreditedDay = lastCreditedDay
        self.updatedAt = updatedAt
    }

    var snapshot: ReviewSnapshot {
        .init(status: status, creditedCorrectCount: creditedCorrectCount, nextReviewDay: nextReviewDay, lastCreditedDay: lastCreditedDay)
    }

    func apply(_ snapshot: ReviewSnapshot) {
        status = snapshot.status
        creditedCorrectCount = snapshot.creditedCorrectCount
        nextReviewDay = snapshot.nextReviewDay
        lastCreditedDay = snapshot.lastCreditedDay
        updatedAt = .now
    }
}

@Model
final class PracticeSession {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var completedAt: Date?
    var phaseRaw: String
    var modeRaw: String
    var currentIndex: Int
    var dayKey: String
    @Relationship(deleteRule: .cascade, inverse: \Attempt.session) var attempts: [Attempt] = []
    @Relationship(deleteRule: .cascade, inverse: \SessionGroupProgress.session) var groupProgress: [SessionGroupProgress] = []

    var phase: SessionPhase {
        get { SessionPhase(rawValue: phaseRaw) ?? .answering }
        set { phaseRaw = newValue.rawValue }
    }
    var mode: SessionMode {
        get { SessionMode(rawValue: modeRaw) ?? .daily }
        set { modeRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), createdAt: Date = .now, phase: SessionPhase = .answering, mode: SessionMode = .daily, currentIndex: Int = 0, dayKey: String) {
        self.id = id
        self.createdAt = createdAt
        self.phaseRaw = phase.rawValue
        self.modeRaw = mode.rawValue
        self.currentIndex = currentIndex
        self.dayKey = dayKey
    }
}

@Model
final class Attempt {
    @Attribute(.unique) var id: UUID
    var orderIndex: Int
    var contextRaw: String
    var draftResultRaw: String?
    var resultRaw: String?
    var presentedAt: Date?
    var committedAt: Date?
    var eligibleForCredit: Bool
    var session: PracticeSession?
    var group: ProblemGroup?
    var question: Question?

    var context: AttemptContext {
        get { AttemptContext(rawValue: contextRaw) ?? .initial }
        set { contextRaw = newValue.rawValue }
    }
    var draftResult: AttemptResult? {
        get { draftResultRaw.flatMap(AttemptResult.init(rawValue:)) }
        set { draftResultRaw = newValue?.rawValue }
    }
    var result: AttemptResult? {
        get { resultRaw.flatMap(AttemptResult.init(rawValue:)) }
        set { resultRaw = newValue?.rawValue }
    }

    init(id: UUID = UUID(), orderIndex: Int, context: AttemptContext, eligibleForCredit: Bool) {
        self.id = id
        self.orderIndex = orderIndex
        self.contextRaw = context.rawValue
        self.eligibleForCredit = eligibleForCredit
    }
}

@Model
final class SessionGroupProgress {
    @Attribute(.unique) var id: UUID
    var stageRaw: String
    var correctionFailureCount: Int
    var session: PracticeSession?
    var group: ProblemGroup?

    var stage: CorrectionStage {
        get { CorrectionStage(rawValue: stageRaw) ?? .pendingReview }
        set { stageRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), stage: CorrectionStage = .pendingReview, correctionFailureCount: Int = 0) {
        self.id = id
        self.stageRaw = stage.rawValue
        self.correctionFailureCount = correctionFailureCount
    }
}
