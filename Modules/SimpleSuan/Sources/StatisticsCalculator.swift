import Foundation

struct SessionStatistics {
    let total: Int
    let correct: Int
    let incorrect: Int
    let accuracy: Double
    let totalDuration: Double
    let averageDuration: Double
    let fastest: Double
    let slowest: Double
}

struct TrendPoint: Identifiable {
    let session: SessionRecord
    let statistics: SessionStatistics
    var id: UUID { session.id }
}

enum StatisticsCalculator {
    static func statistics(for questions: [QuestionRecord]) -> SessionStatistics {
        let total = questions.count
        let correct = questions.filter(\.isCorrect).count
        let duration = questions.reduce(0) { $0 + $1.durationSeconds }
        return SessionStatistics(total: total, correct: correct, incorrect: total - correct,
                                 accuracy: total == 0 ? 0 : Double(correct) / Double(total), totalDuration: duration,
                                 averageDuration: total == 0 ? 0 : duration / Double(total),
                                 fastest: questions.map(\.durationSeconds).min() ?? 0,
                                 slowest: questions.map(\.durationSeconds).max() ?? 0)
    }

    static func statistics(for session: SessionRecord, operation: OperationType? = nil) -> SessionStatistics? {
        let questions = operation.map { target in session.questions.filter { $0.operationType == target } } ?? session.questions
        return questions.isEmpty ? nil : statistics(for: questions)
    }

    static func trend(sessions: [SessionRecord], operation: OperationType?) -> [TrendPoint] {
        sessions.sorted { $0.completedAt < $1.completedAt }.compactMap { session in
            statistics(for: session, operation: operation).map { TrendPoint(session: session, statistics: $0) }
        }.suffix(30).map { $0 }
    }
}
