import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SimpleLianBackup: Codable {
    var formatVersion: Int = 1
    var exportedAt: Date = .now
    var batches: [BatchRecord]
    var groups: [GroupRecord]
    var questions: [QuestionRecord]
    var reviewStates: [ReviewRecord]
    var sessions: [SessionRecord]
    var attempts: [AttemptRecord]
    var progress: [ProgressRecord]
}

struct BatchRecord: Codable { let id: UUID; let title: String; let sourceNote: String?; let importedAt: Date; let schemaVersion: Int; let payloadHash: String }
struct GroupRecord: Codable { let id: UUID; let externalID: String; let title: String; let createdAt: Date; let isArchived: Bool; let batchID: UUID? }
struct QuestionRecord: Codable { let id: UUID; let externalID: String; let kindRaw: String; let promptMarkdown: String; let answerMarkdown: String; let explanationMarkdown: String; let createdAt: Date; let disabledAt: Date?; let disabledReason: String?; let groupID: UUID? }
struct ReviewRecord: Codable { let id: UUID; let statusRaw: String; let creditedCorrectCount: Int; let nextReviewDay: String?; let lastCreditedDay: String?; let updatedAt: Date; let groupID: UUID? }
struct SessionRecord: Codable { let id: UUID; let createdAt: Date; let completedAt: Date?; let phaseRaw: String; let modeRaw: String; let currentIndex: Int; let dayKey: String }
struct AttemptRecord: Codable { let id: UUID; let orderIndex: Int; let contextRaw: String; let draftResultRaw: String?; let resultRaw: String?; let presentedAt: Date?; let committedAt: Date?; let eligibleForCredit: Bool; let sessionID: UUID?; let groupID: UUID?; let questionID: UUID? }
struct ProgressRecord: Codable { let id: UUID; let stageRaw: String; let correctionFailureCount: Int; let sessionID: UUID?; let groupID: UUID? }

enum BackupService {
    static func exportData(context: ModelContext) throws -> Data {
        let batches = try context.fetch(FetchDescriptor<ImportBatch>())
        let groups = try context.fetch(FetchDescriptor<ProblemGroup>())
        let questions = try context.fetch(FetchDescriptor<Question>())
        let reviews = try context.fetch(FetchDescriptor<ReviewState>())
        let sessions = try context.fetch(FetchDescriptor<PracticeSession>())
        let attempts = try context.fetch(FetchDescriptor<Attempt>())
        let progress = try context.fetch(FetchDescriptor<SessionGroupProgress>())
        let backup = SimpleLianBackup(
            batches: batches.map { .init(id: $0.id, title: $0.title, sourceNote: $0.sourceNote, importedAt: $0.importedAt, schemaVersion: $0.schemaVersion, payloadHash: $0.payloadHash) },
            groups: groups.map { .init(id: $0.id, externalID: $0.externalID, title: $0.title, createdAt: $0.createdAt, isArchived: $0.isArchived, batchID: $0.batch?.id) },
            questions: questions.map { .init(id: $0.id, externalID: $0.externalID, kindRaw: $0.kindRaw, promptMarkdown: $0.promptMarkdown, answerMarkdown: $0.answerMarkdown, explanationMarkdown: $0.explanationMarkdown, createdAt: $0.createdAt, disabledAt: $0.disabledAt, disabledReason: $0.disabledReason, groupID: $0.group?.id) },
            reviewStates: reviews.map { .init(id: $0.id, statusRaw: $0.statusRaw, creditedCorrectCount: $0.creditedCorrectCount, nextReviewDay: $0.nextReviewDay, lastCreditedDay: $0.lastCreditedDay, updatedAt: $0.updatedAt, groupID: $0.group?.id) },
            sessions: sessions.map { .init(id: $0.id, createdAt: $0.createdAt, completedAt: $0.completedAt, phaseRaw: $0.phaseRaw, modeRaw: $0.modeRaw, currentIndex: $0.currentIndex, dayKey: $0.dayKey) },
            attempts: attempts.map { .init(id: $0.id, orderIndex: $0.orderIndex, contextRaw: $0.contextRaw, draftResultRaw: $0.draftResultRaw, resultRaw: $0.resultRaw, presentedAt: $0.presentedAt, committedAt: $0.committedAt, eligibleForCredit: $0.eligibleForCredit, sessionID: $0.session?.id, groupID: $0.group?.id, questionID: $0.question?.id) },
            progress: progress.map { .init(id: $0.id, stageRaw: $0.stageRaw, correctionFailureCount: $0.correctionFailureCount, sessionID: $0.session?.id, groupID: $0.group?.id) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(backup)
    }

    static func validate(_ data: Data) throws -> SimpleLianBackup {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(SimpleLianBackup.self, from: data)
        try validateContents(backup)
        return backup
    }

    private static func validateContents(_ backup: SimpleLianBackup) throws {
        guard backup.formatVersion == 1 else { throw BackupFailure.unsupportedVersion }
        let batchIDs = Set(backup.batches.map(\.id))
        let groupIDs = Set(backup.groups.map(\.id))
        let questionIDs = Set(backup.questions.map(\.id))
        let sessionIDs = Set(backup.sessions.map(\.id))
        guard batchIDs.count == backup.batches.count,
              groupIDs.count == backup.groups.count,
              questionIDs.count == backup.questions.count,
              sessionIDs.count == backup.sessions.count,
              Set(backup.reviewStates.map(\.id)).count == backup.reviewStates.count,
              Set(backup.attempts.map(\.id)).count == backup.attempts.count,
              Set(backup.progress.map(\.id)).count == backup.progress.count,
              backup.groups.allSatisfy({ $0.batchID.map(batchIDs.contains) ?? false }),
              backup.questions.allSatisfy({ $0.groupID.map(groupIDs.contains) ?? false }),
              backup.reviewStates.allSatisfy({ $0.groupID.map(groupIDs.contains) ?? false }),
              backup.attempts.allSatisfy({
                  ($0.sessionID.map(sessionIDs.contains) ?? false) &&
                  ($0.groupID.map(groupIDs.contains) ?? false) &&
                  ($0.questionID.map(questionIDs.contains) ?? false)
              }),
              backup.progress.allSatisfy({
                  ($0.sessionID.map(sessionIDs.contains) ?? false) &&
                  ($0.groupID.map(groupIDs.contains) ?? false)
              }) else { throw BackupFailure.invalidRelationships }

        let questions = Dictionary(uniqueKeysWithValues: backup.questions.map { ($0.id, $0) })
        let attemptsBySession = Dictionary(grouping: backup.attempts, by: \.sessionID)
        let progressBySession = Dictionary(grouping: backup.progress, by: \.sessionID)
        guard Set(backup.reviewStates.compactMap(\.groupID)) == groupIDs,
              backup.reviewStates.count == groupIDs.count,
              backup.questions.allSatisfy({ QuestionKind(rawValue: $0.kindRaw) != nil }),
              backup.reviewStates.allSatisfy({
                  ReviewStatus(rawValue: $0.statusRaw) != nil && (0...3).contains($0.creditedCorrectCount)
                      && ($0.nextReviewDay.map(validDay) ?? true) && ($0.lastCreditedDay.map(validDay) ?? true)
              }),
              backup.attempts.allSatisfy({
                  AttemptContext(rawValue: $0.contextRaw) != nil && $0.orderIndex >= 0
                      && ($0.draftResultRaw.map { AttemptResult(rawValue: $0) != nil } ?? true)
                      && ($0.resultRaw.map { AttemptResult(rawValue: $0) != nil } ?? true)
                      && $0.groupID == $0.questionID.flatMap { questions[$0]?.groupID }
              }),
              backup.progress.allSatisfy({
                  CorrectionStage(rawValue: $0.stageRaw) != nil && (0...3).contains($0.correctionFailureCount)
              }),
              backup.sessions.filter({ $0.completedAt == nil }).count <= 1 else { throw BackupFailure.invalidProgress }

        for session in backup.sessions {
            guard let phase = SessionPhase(rawValue: session.phaseRaw),
                  let mode = SessionMode(rawValue: session.modeRaw), validDay(session.dayKey),
                  session.currentIndex >= 0,
                  (phase == .completed) == (session.completedAt != nil),
                  session.completedAt.map({ $0 >= session.createdAt }) ?? true else { throw BackupFailure.invalidProgress }
            let attempts = attemptsBySession[session.id] ?? []
            let progress = progressBySession[session.id] ?? []
            let initial = attempts.filter { $0.contextRaw != AttemptContext.correction.rawValue }
            guard Set(progress.compactMap(\.groupID)).count == progress.count else { throw BackupFailure.invalidProgress }
            switch mode {
            case .daily:
                guard !initial.isEmpty, session.currentIndex < initial.count else { throw BackupFailure.invalidProgress }
            case .targetedCorrection:
                guard initial.isEmpty, !progress.isEmpty, session.currentIndex == 0,
                      phase != .answering && phase != .marking else { throw BackupFailure.invalidProgress }
            }
            if phase == .correction && progress.isEmpty { throw BackupFailure.invalidProgress }
            for value in progress where value.stageRaw == CorrectionStage.pendingFollowup.rawValue
                || value.stageRaw == CorrectionStage.awaitingGrade.rawValue {
                guard attempts.filter({ $0.contextRaw == AttemptContext.correction.rawValue
                    && $0.groupID == value.groupID && $0.resultRaw == nil }).count == 1 else { throw BackupFailure.invalidProgress }
            }
        }
    }

    private static func validDay(_ key: String) -> Bool {
        key.count == 10 && DayKey.adding(days: 0, to: key, calendar: .gregorianUTC) == key
    }

    static func restore(_ backup: SimpleLianBackup, context: ModelContext) throws {
        // Validate again here so callers cannot bypass checks before replacement.
        try validateContents(backup)
        try context.transaction {
            for value in try context.fetch(FetchDescriptor<PracticeSession>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<ImportBatch>()) { context.delete(value) }
            try context.save()

            var batches: [UUID: ImportBatch] = [:]
            for record in backup.batches {
                let value = ImportBatch(id: record.id, title: record.title, sourceNote: record.sourceNote, importedAt: record.importedAt, schemaVersion: record.schemaVersion, payloadHash: record.payloadHash)
                context.insert(value); batches[value.id] = value
            }
            var groups: [UUID: ProblemGroup] = [:]
            for record in backup.groups {
                let value = ProblemGroup(id: record.id, externalID: record.externalID, title: record.title, createdAt: record.createdAt, isArchived: record.isArchived)
                if let batchID = record.batchID { batches[batchID]?.groups.append(value) }
                context.insert(value); groups[value.id] = value
            }
            var questions: [UUID: Question] = [:]
            for record in backup.questions {
                let value = Question(id: record.id, externalID: record.externalID, kind: QuestionKind(rawValue: record.kindRaw) ?? .near, promptMarkdown: record.promptMarkdown, answerMarkdown: record.answerMarkdown, explanationMarkdown: record.explanationMarkdown, createdAt: record.createdAt)
                value.disabledAt = record.disabledAt; value.disabledReason = record.disabledReason
                if let groupID = record.groupID { groups[groupID]?.questions.append(value) }
                context.insert(value); questions[value.id] = value
            }
            for record in backup.reviewStates {
                let value = ReviewState(id: record.id, status: ReviewStatus(rawValue: record.statusRaw) ?? .new, creditedCorrectCount: record.creditedCorrectCount, nextReviewDay: record.nextReviewDay, lastCreditedDay: record.lastCreditedDay, updatedAt: record.updatedAt)
                if let groupID = record.groupID { groups[groupID]?.reviewState = value }
                context.insert(value)
            }
            var sessions: [UUID: PracticeSession] = [:]
            for record in backup.sessions {
                let value = PracticeSession(id: record.id, createdAt: record.createdAt, phase: SessionPhase(rawValue: record.phaseRaw) ?? .answering, mode: SessionMode(rawValue: record.modeRaw) ?? .daily, currentIndex: record.currentIndex, dayKey: record.dayKey)
                value.completedAt = record.completedAt
                context.insert(value); sessions[value.id] = value
            }
            for record in backup.attempts {
                let value = Attempt(id: record.id, orderIndex: record.orderIndex, context: AttemptContext(rawValue: record.contextRaw) ?? .initial, eligibleForCredit: record.eligibleForCredit)
                value.draftResultRaw = record.draftResultRaw; value.resultRaw = record.resultRaw; value.presentedAt = record.presentedAt; value.committedAt = record.committedAt
                if let sessionID = record.sessionID { sessions[sessionID]?.attempts.append(value) }
                if let groupID = record.groupID { value.group = groups[groupID] }
                if let questionID = record.questionID { value.question = questions[questionID] }
                context.insert(value)
            }
            for record in backup.progress {
                let value = SessionGroupProgress(id: record.id, stage: CorrectionStage(rawValue: record.stageRaw) ?? .pendingReview, correctionFailureCount: record.correctionFailureCount)
                if let sessionID = record.sessionID { sessions[sessionID]?.groupProgress.append(value) }
                if let groupID = record.groupID { value.group = groups[groupID] }
                context.insert(value)
            }
            try context.save()
        }
    }
}

enum BackupFailure: LocalizedError {
    case unsupportedVersion, invalidRelationships, invalidProgress
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "备份版本不受支持。"
        case .invalidRelationships: "备份中的题目关系不完整，不能恢复。"
        case .invalidProgress: "备份中的练习进度或状态无效，不能恢复。现有数据未改变。"
        }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
