import Foundation

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

    var cardsComplete: Bool { requiredCardIDs.isSubset(of: answeredCardIDs) }
    var isComplete: Bool { hasActivity && cardsComplete && dictationComplete }
}

enum StudyStreak {
    static func count(completedDays: [StudyCompletionDay], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let keys = Set(completedDays.filter { $0.isComplete && $0.completedAt != nil }.map(\.dayKey))
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

    static func dictationFinished(phase: String, items: [DictationItem]) -> Bool {
        phase == DictationPhase.complete.rawValue && items.allSatisfy {
            $0.formalResult != nil && !$0.awaitsVerification && !$0.isDeferred
                && ($0.formalResult == true || ($0.remediationCopyCount >= 3
                    && $0.retestAttempted && $0.remediationPassed))
        }
    }
}
