import Foundation

struct ReviewStateSnapshot: Identifiable, Equatable {
    let id: UUID
    let wordID: UUID
    let english: String
    let normalizedEnglish: String
    let chinese: String
    let direction: ReviewDirection
    let level: Int
    let nextReviewDate: Date
    let formalKnownCount: Int
    let formalUnknownCount: Int
    let consecutiveKnown: Int
    let lastFormalResult: ReviewResult?
    var extraPracticeAttempts: Int = 0

    var formalAttempts: Int { formalKnownCount + formalUnknownCount }
}

struct ReviewTask: Identifiable, Equatable {
    enum Kind: Equatable {
        case base
        case sameSessionRetry(attempt: Int)
    }

    let id: UUID
    let state: ReviewStateSnapshot
    let kind: Kind

    init(id: UUID = UUID(), state: ReviewStateSnapshot, kind: Kind = .base) {
        self.id = id
        self.state = state
        self.kind = kind
    }

    var wordID: UUID { state.wordID }
    var direction: ReviewDirection { state.direction }
    var isRetry: Bool {
        if case .sameSessionRetry = kind { return true }
        return false
    }

    var retryAttempt: Int {
        if case .sameSessionRetry(let attempt) = kind { return attempt }
        return 0
    }

    var frontText: String {
        direction == .englishToChinese ? state.english : state.chinese
    }

    var backText: String {
        direction == .englishToChinese ? state.chinese : state.english
    }
}
