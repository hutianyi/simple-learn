import Foundation

public struct ValidationIssue: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }
    public let id: String
    public let severity: Severity
    public let location: String
    public let message: String

    public init(id: String, severity: Severity, location: String, message: String) {
        self.id = id
        self.severity = severity
        self.location = location
        self.message = message
    }
}

public struct ValidationReport: Sendable {
    public let issues: [ValidationIssue]
    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    public var canImport: Bool { errors.isEmpty }
}

public enum PayloadValidator {
    public static func validate(_ payload: SimpleLianPayload) -> ValidationReport {
        var issues: [ValidationIssue] = []
        func add(_ severity: ValidationIssue.Severity, _ location: String, _ message: String) {
            issues.append(.init(id: "\(issues.count)-\(location)", severity: severity, location: location, message: message))
        }

        if payload.schemaVersion != 1 { add(.error, "schema_version", "当前只支持版本 1。") }
        if payload.batchTitle.trimmed.isEmpty { add(.error, "batch_title", "批次标题不能为空。") }
        if payload.groups.isEmpty { add(.error, "groups", "至少需要一个题型组。") }

        var groupIDs = Set<String>()
        var questionIDs = Set<String>()
        for (index, group) in payload.groups.enumerated() {
            let location = "groups[\(index)]"
            if group.groupID.trimmed.isEmpty { add(.error, location, "group_id 不能为空。") }
            if !groupIDs.insert(group.groupID).inserted { add(.error, location, "group_id 重复：\(group.groupID)") }
            if group.title.trimmed.isEmpty { add(.error, location, "题型名称不能为空。") }
            validateQuestion(group.original, at: "\(location).original", kind: nil, ids: &questionIDs, add: add)
            if group.variants.isEmpty { add(.warning, location, "没有扩展题，首次练习与后续复习无法正常选题。") }
            let nearCount = group.variants.filter { $0.variantKind == .near }.count
            let transferCount = group.variants.filter { $0.variantKind == .transfer }.count
            if nearCount < 12 { add(.warning, location, "近似题只有 \(nearCount) 道，建议 12 道。") }
            if transferCount < 8 { add(.warning, location, "迁移题只有 \(transferCount) 道，建议 8 道。") }
            for (variantIndex, variant) in group.variants.enumerated() {
                let q = QuestionPayload(questionID: variant.questionID, promptMarkdown: variant.promptMarkdown, answerMarkdown: variant.answerMarkdown, explanationMarkdown: variant.explanationMarkdown)
                validateQuestion(q, at: "\(location).variants[\(variantIndex)]", kind: variant.variantKind, ids: &questionIDs, add: add)
            }
        }
        return ValidationReport(issues: issues)
    }

    private static func validateQuestion(
        _ question: QuestionPayload,
        at location: String,
        kind: VariantKind?,
        ids: inout Set<String>,
        add: (ValidationIssue.Severity, String, String) -> Void
    ) {
        if question.questionID.trimmed.isEmpty { add(.error, location, "question_id 不能为空。") }
        if !ids.insert(question.questionID).inserted { add(.error, location, "question_id 重复：\(question.questionID)") }
        if question.promptMarkdown.trimmed.isEmpty { add(.error, location, "题目不能为空。") }
        if question.answerMarkdown.trimmed.isEmpty { add(.error, location, "答案不能为空。") }
        if question.explanationMarkdown.trimmed.isEmpty { add(.warning, location, "解析为空。") }
        for (field, text) in [("题目", question.promptMarkdown), ("答案", question.answerMarkdown), ("解析", question.explanationMarkdown)] {
            if MarkdownSafety.containsUnsupportedContent(text) {
                add(.error, location, "\(field)包含图片、HTML 或 LaTeX；第一版只支持纯文本 Markdown。")
            }
        }
        _ = kind
    }
}

public enum MarkdownSafety {
    public static func containsUnsupportedContent(_ text: String) -> Bool {
        if text.contains("![") || text.contains("\\(") || text.contains("\\[") { return true }
        return text.range(of: #"<\s*/?\s*[A-Za-z][^>]*>"#, options: .regularExpression) != nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
