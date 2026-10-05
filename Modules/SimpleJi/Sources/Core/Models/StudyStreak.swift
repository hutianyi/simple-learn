import Foundation
import StudyShell

struct StudyRepairPlan: Codable, Equatable {
    enum Status: String, Codable { case accepted, declined, abandoned, completed }
    let yesterdayKey: String
    let previousStreak: Int
    let extraCardIDs: [UUID]
    var dictationDayID: UUID?
    var cardsComplete: Bool
    var dictationComplete: Bool
    var status: Status
    var restoredAt: Date? = nil
}

struct StudyCompletionScope: Codable, Equatable {
    var baselineWordIDs: Set<UUID>?
    var masteredTerms: Set<String> = []
}

struct StudyCompletionDay: Codable, Equatable {
    let dayKey: String
    let timeZoneID: String
    var requiredCardIDs: Set<UUID> = []
    var answeredCardIDs: Set<UUID> = []
    var dictationComplete = false
    var hasActivity = false
    var completedAt: Date?
    var scope = StudyCompletionScope()
    var repair: StudyRepairPlan? = nil

    var cardsComplete: Bool { requiredCardIDs.isSubset(of: answeredCardIDs) }
    var normalTasksComplete: Bool { hasActivity && cardsComplete && dictationComplete }
    var isComplete: Bool { normalTasksComplete && repair?.status != .accepted }
}

enum StudyStreak {
    static func count(completedDays: [StudyCompletionDay], now: Date = Date(), calendar: Calendar = .current, historicalKeys: Set<String> = []) -> Int {
        let keys = completionKeys(completedDays: completedDays, historicalKeys: historicalKeys, now: now, calendar: calendar)
        var cursor = calendar.startOfDay(for: now)
        if !keys.contains(DictationEligibility.dayKey(for: cursor, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while keys.contains(DictationEligibility.dayKey(for: cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    // Historical sessions predate the complete daily task snapshots. Never let this
    // compatibility rule replace an incomplete day recorded under the new rule.
    static func completionKeys(completedDays: [StudyCompletionDay], historicalKeys: Set<String>,
                               now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        let cutoff = completedDays.map(\.dayKey).min()
            ?? DictationEligibility.dayKey(for: now, calendar: calendar)
        return Set(completedDays.filter { $0.isComplete && ($0.completedAt.map { $0 <= now } ?? false) }.map(\.dayKey))
            .union(historicalKeys.filter { $0 < cutoff })
            .union(repairedKeys(completedDays: completedDays, now: now))
    }

    static func repairedKeys(completedDays: [StudyCompletionDay], now: Date = Date()) -> Set<String> {
        Set(completedDays.compactMap { day in
            guard let plan = day.repair, plan.status == .completed,
                  plan.cardsComplete, plan.dictationComplete,
                  let completedAt = plan.restoredAt ?? day.completedAt, completedAt <= now,
                  let zone = TimeZone(identifier: day.timeZoneID),
                  OneDayStreakRepair.dayKey(completedAt, calendar: DictationEligibility.calendar(timeZone: zone)) == day.dayKey,
                  OneDayStreakRepair.isYesterday(plan.yesterdayKey, on: completedAt,
                    calendar: DictationEligibility.calendar(timeZone: zone)) else { return nil }
            return plan.yesterdayKey
        })
    }

    struct HistoricalSession {
        let startedAt: Date
        let finishedAt: Date?
        let completed: Bool
        let required: Int
        let answered: Int
    }

    static func historicalCardsFinished(sessions: [HistoricalSession], calendar: Calendar) -> Bool {
        guard let last = sessions.max(by: { $0.startedAt < $1.startedAt }),
              let finish = last.finishedAt else { return false }
        return last.completed && last.required > 0 && last.answered >= last.required
            && calendar.isDate(last.startedAt, inSameDayAs: finish)
    }

    static func historicalDictationFinished(dayKey: String, phase: String, items: [DictationItem],
                                           successfulRetests: [UUID: [Date]], calendar: Calendar) -> Bool {
        dictationFinished(phase: phase, items: items) && items.allSatisfy { item in
            guard let submitted = item.formalSubmittedAt,
                  DictationEligibility.dayKey(for: submitted, calendar: calendar) == dayKey else { return false }
            return item.formalResult == true || (successfulRetests[item.wordID] ?? []).contains {
                DictationEligibility.dayKey(for: $0, calendar: calendar) == dayKey
            }
        }
    }

    static func shouldCelebrate(day: StudyCompletionDay, todayKey: String, lastCelebratedKey: String) -> Bool {
        day.dayKey == todayKey && day.isComplete && day.completedAt != nil && lastCelebratedKey != todayKey
    }

    static func heatmapWeeks(now: Date = Date(), calendar: Calendar = .current) -> [[Date]] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -364, to: today) else { return [] }
        // Monday is the first row, regardless of the device's locale.
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        guard var cursor = calendar.date(byAdding: .day, value: -offset, to: first) else { return [] }
        var weeks: [[Date]] = []
        while cursor <= today {
            weeks.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: cursor) })
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return weeks
    }

    static func dictationFinished(phase: String, items: [DictationItem]) -> Bool {
        phase == DictationPhase.complete.rawValue && items.allSatisfy {
            $0.formalResult != nil && !$0.awaitsVerification && !$0.isDeferred
                && ($0.formalResult == true || ($0.remediationCopyCount >= 3
                    && $0.retestAttempted && $0.remediationPassed))
        }
    }
}
