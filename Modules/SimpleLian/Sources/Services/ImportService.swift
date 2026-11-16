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

struct FileImportPreview: Identifiable {
    enum Status { case ready, duplicate, invalid, imported, failed }

    let id = UUID()
    let fileName: String
    let preview: ImportPreview?
    var status: Status
    var message: String?
}

enum ImportService {
    @MainActor
    static func previewFiles(_ urls: [URL], context: ModelContext) async -> [FileImportPreview] {
        var files: [FileImportPreview] = []
        var seenHashes = Set<String>()
        for url in urls {
            guard !Task.isCancelled else { break }
            do {
                let text = try await Task.detached { try ImportFileReader.read(url) }.value
                guard !Task.isCancelled else { break }
                let preview = try preview(text: text, context: context)
                let status: FileImportPreview.Status
                let message: String?
                if !preview.report.canImport {
                    status = .invalid
                    message = "内容检查未通过，请修正后重新选择。"
                } else if preview.isDuplicate {
                    status = .duplicate
                    message = "题库中已有相同内容，将自动跳过。"
                } else if !seenHashes.insert(preview.payloadHash).inserted {
                    status = .duplicate
                    message = "与本次选择的其他文件内容相同，将自动跳过。"
                } else {
                    status = .ready
                    message = nil
                }
                files.append(FileImportPreview(fileName: url.lastPathComponent, preview: preview, status: status, message: message))
            } catch {
                files.append(FileImportPreview(fileName: url.lastPathComponent, preview: nil, status: .invalid, message: error.localizedDescription))
            }
        }
        return files
    }

    @MainActor
    static func commitFiles(_ files: [FileImportPreview], context: ModelContext) -> [FileImportPreview] {
        files.map { file in
            guard file.status == .ready, let preview = file.preview else { return file }
            var result = file
            do {
                try commit(preview, context: context)
                result.status = .imported
                result.message = "已添加到题库。"
            } catch ImportFailure.duplicate {
                result.status = .duplicate
                result.message = "题库中已有相同内容，已跳过。"
            } catch {
                result.status = .failed
                result.message = error.localizedDescription
            }
            return result
        }
    }

    static func preview(text: String, context: ModelContext) throws -> ImportPreview {
        let payload = try ImportParser.parse(text)
        let report = PayloadValidator.validate(payload)
        let hash = try PayloadHash.sha256(payload)
        return ImportPreview(payload: payload, report: report, payloadHash: hash, isDuplicate: try contains(hash: hash, context: context))
    }

    @discardableResult
    static func commit(_ preview: ImportPreview, context: ModelContext) throws -> ImportBatch {
        guard preview.report.canImport else { throw ImportFailure.validation }

        let batch = ImportBatch(
            title: preview.payload.batchTitle,
            sourceNote: preview.payload.sourceNote,
            schemaVersion: preview.payload.schemaVersion,
            payloadHash: preview.payloadHash
        )
        try context.transaction {
            // Check again at commit time so stale previews and retries cannot add duplicates.
            guard try !contains(hash: preview.payloadHash, context: context) else { throw ImportFailure.duplicate }
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

    private static func contains(hash: String, context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.payloadHash == hash })
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
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
