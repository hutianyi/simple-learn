import Foundation

enum QuestionKind: String, Codable, CaseIterable {
    case original, near, transfer
}

enum SessionPhase: String, Codable {
    case answering, marking, correction, summary, completed
}

enum SessionMode: String, Codable {
    case daily, targetedCorrection
}

enum AttemptContext: String, Codable {
    case initial, scheduled, correction
}

enum AttemptResult: String, Codable, CaseIterable {
    case correct, wrong, excluded

    var label: String {
        switch self {
        case .correct: "做对了"
        case .wrong: "做错了"
        case .excluded: "题目有问题"
        }
    }
}

enum CorrectionStage: String, Codable {
    case pendingReview, pendingFollowup, awaitingGrade, passed, needsExplanation, materialShortage
}
