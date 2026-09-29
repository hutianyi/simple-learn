import Foundation
import SwiftData

struct ImportPreview {
    let payload: SimpleLianPayload
    let report: ValidationReport
    let payloadHash: String
    let isDuplicate: Bool

    var groupCount: Int { payload.groups.count }
    var variantCount: Int { payload.groups.reduce(0) { $0 + $1.variants.count } }
}

enum ImportService {
    static func preview(text: String, context: ModelContext) throws -> ImportPreview {
        let payload = try ImportParser.parse(text)
        let report = PayloadValidator.validate(payload)
        let hash = try PayloadHash.sha256(payload)
        var descriptor = FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.payloadHash == hash })
        descriptor.fetchLimit = 1
        return ImportPreview(payload: payload, report: report, payloadHash: hash, isDuplicate: try !context.fetch(descriptor).isEmpty)
    }

    @discardableResult
    static func commit(_ preview: ImportPreview, context: ModelContext, allowDuplicate: Bool = false) throws -> ImportBatch {
        guard preview.report.canImport else { throw ImportFailure.validation }
        guard allowDuplicate || !preview.isDuplicate else { throw ImportFailure.duplicate }

        let batch = ImportBatch(
            title: preview.payload.batchTitle,
            sourceNote: preview.payload.sourceNote,
            schemaVersion: preview.payload.schemaVersion,
            payloadHash: preview.payloadHash
        )
        try context.transaction {
            context.insert(batch)
            for sourceGroup in preview.payload.groups {
                let group = ProblemGroup(externalID: sourceGroup.groupID, title: sourceGroup.title)
                batch.groups.append(group)
                context.insert(group)

                let state = ReviewState(nextReviewDay: DayKey.make(from: .now))
                group.reviewState = state
                context.insert(state)

                let original = makeQuestion(sourceGroup.original, kind: .original)
                group.questions.append(original)
                context.insert(original)

                for variant in sourceGroup.variants {
                    let payload = QuestionPayload(questionID: variant.questionID, promptMarkdown: variant.promptMarkdown, answerMarkdown: variant.answerMarkdown, explanationMarkdown: variant.explanationMarkdown)
                    let question = makeQuestion(payload, kind: variant.variantKind == .near ? .near : .transfer)
                    group.questions.append(question)
                    context.insert(question)
                }
            }
            try context.save()
        }
        return batch
    }

    private static func makeQuestion(_ source: QuestionPayload, kind: QuestionKind) -> Question {
        Question(
            externalID: source.questionID,
            kind: kind,
            promptMarkdown: source.promptMarkdown,
            answerMarkdown: source.answerMarkdown,
            explanationMarkdown: source.explanationMarkdown
        )
    }
}

enum ImportFailure: LocalizedError {
    case validation, duplicate
    var errorDescription: String? {
        switch self {
        case .validation: "导入内容仍有错误，请先修正。"
        case .duplicate: "这份题库已经导入过。"
        }
    }
}
