import CryptoKit
import Foundation

public struct SimpleLianPayload: Codable, Sendable {
    public var schemaVersion: Int
    public var batchTitle: String
    public var sourceNote: String?
    public var groups: [GroupPayload]

    public init(schemaVersion: Int, batchTitle: String, sourceNote: String? = nil, groups: [GroupPayload]) {
        self.schemaVersion = schemaVersion
        self.batchTitle = batchTitle
        self.sourceNote = sourceNote
        self.groups = groups
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case batchTitle = "batch_title"
        case sourceNote = "source_note"
        case groups
    }
}

public struct GroupPayload: Codable, Sendable {
    public var groupID: String
    public var title: String
    public var original: QuestionPayload
    public var variants: [VariantPayload]

    public init(groupID: String, title: String, original: QuestionPayload, variants: [VariantPayload]) {
        self.groupID = groupID
        self.title = title
        self.original = original
        self.variants = variants
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case title, original, variants
    }
}

public struct QuestionPayload: Codable, Sendable {
    public var questionID: String
    public var promptMarkdown: String
    public var answerMarkdown: String
    public var explanationMarkdown: String

    public init(questionID: String, promptMarkdown: String, answerMarkdown: String, explanationMarkdown: String) {
        self.questionID = questionID
        self.promptMarkdown = promptMarkdown
        self.answerMarkdown = answerMarkdown
        self.explanationMarkdown = explanationMarkdown
    }

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case promptMarkdown = "prompt_markdown"
        case answerMarkdown = "answer_markdown"
        case explanationMarkdown = "explanation_markdown"
    }
}

public struct VariantPayload: Codable, Sendable {
    public var questionID: String
    public var variantKind: VariantKind
    public var promptMarkdown: String
    public var answerMarkdown: String
    public var explanationMarkdown: String

    public init(questionID: String, variantKind: VariantKind, promptMarkdown: String, answerMarkdown: String, explanationMarkdown: String) {
        self.questionID = questionID
        self.variantKind = variantKind
        self.promptMarkdown = promptMarkdown
        self.answerMarkdown = answerMarkdown
        self.explanationMarkdown = explanationMarkdown
    }

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case variantKind = "variant_kind"
        case promptMarkdown = "prompt_markdown"
        case answerMarkdown = "answer_markdown"
        case explanationMarkdown = "explanation_markdown"
    }
}

public enum VariantKind: String, Codable, CaseIterable, Sendable {
    case near
    case transfer
}

public enum PayloadHash {
    public static func sha256(_ payload: SimpleLianPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
