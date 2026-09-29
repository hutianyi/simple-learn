import Foundation

public enum ReviewStatus: String, Codable, Sendable {
    case new, scheduled, pendingCorrection, needsExplanation, mastered
}

public struct ReviewSnapshot: Equatable, Sendable {
    public var status: ReviewStatus
    public var creditedCorrectCount: Int
    public var nextReviewDay: String?
    public var lastCreditedDay: String?

    public init(status: ReviewStatus = .new, creditedCorrectCount: Int = 0, nextReviewDay: String? = nil, lastCreditedDay: String? = nil) {
        self.status = status
        self.creditedCorrectCount = creditedCorrectCount
        self.nextReviewDay = nextReviewDay
        self.lastCreditedDay = lastCreditedDay
    }
}

public enum ReviewEvent: Sendable {
    case formalCorrect(day: String)
    case formalWrong(day: String)
    case correctionSucceeded(day: String)
    case explanationNeeded
    case restart(day: String)
}

public enum ReviewScheduler {
    public static func apply(_ event: ReviewEvent, to current: ReviewSnapshot, calendar: Calendar = .gregorianUTC) -> ReviewSnapshot {
        var next = current
        switch event {
        case .formalCorrect(let day):
            guard current.status != .mastered, current.lastCreditedDay != day else { return current }
            next.creditedCorrectCount = min(3, current.creditedCorrectCount + 1)
            next.lastCreditedDay = day
            if next.creditedCorrectCount >= 3 {
                next.status = .mastered
                next.nextReviewDay = nil
            } else {
                next.status = .scheduled
                next.nextReviewDay = DayKey.adding(days: next.creditedCorrectCount == 1 ? 7 : 14, to: day, calendar: calendar)
            }
        case .formalWrong(let day):
            next.status = .pendingCorrection
            next.creditedCorrectCount = 0
            next.lastCreditedDay = nil
            next.nextReviewDay = day
        case .correctionSucceeded(let day):
            next.status = .scheduled
            next.creditedCorrectCount = 0
            next.lastCreditedDay = nil
            next.nextReviewDay = DayKey.adding(days: 3, to: day, calendar: calendar)
        case .explanationNeeded:
            next.status = .needsExplanation
            next.creditedCorrectCount = 0
            next.lastCreditedDay = nil
            next.nextReviewDay = nil
        case .restart(let day):
            next.status = .new
            next.creditedCorrectCount = 0
            next.lastCreditedDay = nil
            next.nextReviewDay = day
        }
        return next
    }
}

public enum DayKey {
    public static func make(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func adding(days: Int, to key: String, calendar: Calendar = .current) -> String? {
        let bits = key.split(separator: "-").compactMap { Int($0) }
        guard bits.count == 3,
              let date = calendar.date(from: DateComponents(year: bits[0], month: bits[1], day: bits[2])),
              let result = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return make(from: result, calendar: calendar)
    }
}

public extension Calendar {
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
