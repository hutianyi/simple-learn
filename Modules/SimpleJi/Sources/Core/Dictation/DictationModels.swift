import Foundation

enum DictationPhase: String, Codable {
    case firstPass
    case firstPassSummary
    case remediationCopy
    case retest
    case complete
}

enum DictationFailureReason: String, Codable {
    case spelling
    case unknown
    case timeout
    case recognition
}

struct DictationItem: Codable, Equatable, Identifiable {
    let wordID: UUID
    let english: String
    let chinese: String
    var formalResult: Bool?
    var formalReason: DictationFailureReason?
    var formalSubmittedAt: Date?
    var remediationCopyCount = 0
    var remediationPassed = false
    var remediationRound = 0
    var retestAttempted = false
    var recognitionFailures = 0
    var remainingSeconds: Double = 30
    var isWriting = false
    var interruptionCount = 0
    var isBaseline: Bool? = nil
    // Optional fields keep older saved queues and backups readable.
    var isNewWord: Bool? = nil
    var consecutiveCopyFailures: Int? = nil
    var keyboardAllowed: Bool? = nil
    var deferred: Bool? = nil
    var pendingHandwriting: String? = nil
    var keyboardDeadline: Date? = nil
    var formalInputMethod: String? = nil
    var retestInputMethod: String? = nil

    var awaitsVerification: Bool { pendingHandwriting != nil }

    var isDeferred: Bool { deferred == true }
    var allowsKeyboard: Bool { keyboardAllowed == true }

    var id: UUID { wordID }
    var needsRemediation: Bool { formalResult == false && !remediationPassed }
    var belongsToBaseline: Bool { isBaseline == true }
}

struct BaselineCampaignSnapshot: Codable, Equatable {
    let selectedWordIDs: [UUID]
    let activatedAt: Date
}

struct BaselineCandidate: Identifiable, Equatable {
    let id: UUID
    let english: String
    let chinese: String
    let createdAt: Date
    let importPosition: Int64
}

struct BaselineProgress: Equatable {
    let total: Int
    let completed: Int

    var remaining: Int { max(0, total - completed) }
}

struct DictationDay: Codable, Equatable {
    let id: UUID
    let dayKey: String
    let timeZoneID: String
    var limit: Int
    var phase: DictationPhase
    var items: [DictationItem]
    let createdAt: Date
    var updatedAt: Date

    var firstPassAnswered: Int { items.filter { $0.formalResult != nil }.count }
    var firstPassCorrect: Int { items.filter { $0.formalResult == true }.count }
    var firstPassWrong: Int { items.filter { $0.formalResult == false }.count }
    var unresolved: Int { items.filter(\.needsRemediation).count }
    var isStreakRepair: Bool { dayKey.hasSuffix("#repair") }
    var firstPassAccuracy: Double? {
        guard firstPassAnswered > 0 else { return nil }
        return Double(firstPassCorrect) / Double(firstPassAnswered)
    }
}

enum DictationKeyboardClock {
    static let duration: TimeInterval = 60

    static func remaining(until deadline: Date, now: Date = Date()) -> TimeInterval {
        max(0, min(duration, deadline.timeIntervalSince(now)))
    }
}

enum DictationAnswerMatcher {
    static func normalize(_ text: String) -> String {
        EnglishNormalizer.normalize(text)
    }

    static func matches(_ recognized: String, answer: String) -> Bool {
        let normalized = normalize(recognized)
        return !normalized.isEmpty && normalized == normalize(answer)
    }
}

struct DictationCardEvent {
    let reviewedAt: Date
    let direction: ReviewDirection
    let result: ReviewResult
    let mode: PracticeMode
    let isSameSessionRetry: Bool
    let englishSnapshot: String
}

struct InitialCopyPrompt: Identifiable, Equatable {
    let wordID: UUID
    let english: String
    let chinese: String
    let completedCopies: Int
    var consecutiveFailures: Int = 0
    var keyboardAllowed: Bool = false

    var id: UUID { wordID }
}

enum DictationSubmission {
    case retry(DictationDay)
    case result(DictationDay, correct: Bool, reason: DictationFailureReason?)
}

enum DictationEligibility {
    static let dailyNewWordLimit = 5

    static func canStartDirectly(
        word: WordEntity, now: Date, calendar: Calendar = calendar()
    ) -> Bool {
        if let state = word.dictationState {
            guard state.englishVersion == DictationAnswerMatcher.normalize(word.english),
                  state.totalFormal == 0, state.initialCopyCompletedAt == nil,
                  (state.formalNotBefore ?? .distantPast) <= now else { return false }
            // Continue words already admitted to the old first-copy workflow.
            if state.initialCopyCount > 0 { return true }
        }
        let events = word.events.compactMap { event -> DictationCardEvent? in
            guard let direction = ReviewDirection(rawValue: event.direction),
                  let result = ReviewResult(rawValue: event.result),
                  let mode = PracticeMode(rawValue: event.practiceMode) else { return nil }
            return DictationCardEvent(
                reviewedAt: event.reviewedAt, direction: direction, result: result,
                mode: mode, isSameSessionRetry: event.isSameSessionRetry,
                englishSnapshot: event.wordEnglishSnapshot
            )
        }
        return qualifies(events: events, currentEnglish: word.english, calendar: calendar)
    }

    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func dayKey(for date: Date, calendar: Calendar = calendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func nextDay(after date: Date, calendar: Calendar = calendar()) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    static func qualifies(
        events: [DictationCardEvent],
        currentEnglish: String,
        calendar: Calendar = calendar()
    ) -> Bool {
        let expected = EnglishNormalizer.normalize(currentEnglish)
        let formal = events
            .filter {
                $0.direction == .chineseToEnglish
                    && $0.mode == .scheduled
                    && !$0.isSameSessionRetry
                    && EnglishNormalizer.normalize($0.englishSnapshot) == expected
            }
            .sorted { $0.reviewedAt < $1.reviewedAt }
        var firstByDay: [String: ReviewResult] = [:]
        for event in formal {
            let key = dayKey(for: event.reviewedAt, calendar: calendar)
            if firstByDay[key] == nil { firstByDay[key] = event.result }
        }
        return firstByDay.values.filter { $0 == .known }.count >= 2
    }
}
