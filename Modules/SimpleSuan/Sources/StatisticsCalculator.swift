import Foundation
import StudyShell

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

struct PracticeActivity {
    let calendar: Calendar
    let today: Date
    let questionCounts: [Date: Int]
    let repairedKeys: Set<String>

    init(sessions: [SessionRecord], now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        // Only saved, completed batches contribute; midnight follows each answer's date.
        questionCounts = sessions.filter { $0.isPartial != true }.flatMap(\.questions).reduce(into: [:]) { counts, question in
            guard question.answeredAt <= now else { return }
            counts[calendar.startOfDay(for: question.answeredAt), default: 0] += 1
        }
        repairedKeys = Set(sessions.filter { $0.completedAt <= now }.compactMap { $0.validRepairKey(calendar: calendar) })
    }

    var firstDay: Date { calendar.date(byAdding: .day, value: -364, to: today) ?? today }
    var todayCount: Int { count(on: today) }
    var completedKeys: Set<String> {
        Set(questionCounts.keys.map { OneDayStreakRepair.dayKey($0, calendar: calendar) }).union(repairedKeys)
    }
    var annualPracticeDays: Int {
        completedKeys.filter { $0 >= OneDayStreakRepair.dayKey(firstDay, calendar: calendar)
            && $0 <= OneDayStreakRepair.dayKey(today, calendar: calendar) }.count
    }
    var streak: Int {
        var cursor = today
        if !completedKeys.contains(OneDayStreakRepair.dayKey(cursor, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var days = 0
        while completedKeys.contains(OneDayStreakRepair.dayKey(cursor, calendar: calendar)) {
            days += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return days
    }

    func count(on date: Date) -> Int { questionCounts[calendar.startOfDay(for: date)] ?? 0 }
    func isRepaired(_ date: Date) -> Bool { repairedKeys.contains(OneDayStreakRepair.dayKey(date, calendar: calendar)) }

    static func intensity(for count: Int) -> Double {
        guard count > 0 else { return 0 }
        // Keep increasing beyond the usual 40 questions, without a daily ceiling.
        return 0.22 + 0.78 * Double(count) / (Double(count) + 40)
    }

    var weeks: [[Date]] {
        let offset = (calendar.component(.weekday, from: firstDay) + 5) % 7
        guard var cursor = calendar.date(byAdding: .day, value: -offset, to: firstDay) else { return [] }
        var result: [[Date]] = []
        while cursor <= today {
            result.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: cursor) })
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return result
    }
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
