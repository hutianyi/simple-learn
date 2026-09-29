import Foundation

enum ReviewQueueBuilder {
    static let preferredOppositeDirectionGap = 5
    static let maximumRetryCount = 2

    static func buildBaseQueue(
        from states: [ReviewStateSnapshot],
        sessionLimit: Int?,
        today: Date,
        calendar: Calendar = .current
    ) -> [ReviewTask] {
        let startOfToday = calendar.startOfDay(for: today)
        let ranked = states
            .filter { calendar.startOfDay(for: $0.nextReviewDate) <= startOfToday }
            .sorted { lhs, rhs in
                compare(lhs, rhs, today: startOfToday, calendar: calendar)
            }

        let limit = sessionLimit.flatMap { $0 > 0 ? $0 : nil } ?? ranked.count
        var pending = ranked
        var result: [ReviewTask] = []

        while !pending.isEmpty, result.count < limit {
            if let preferredIndex = pending.firstIndex(where: { candidate in
                isPreferred(candidate, after: result)
            }) {
                let state = pending.remove(at: preferredIndex)
                result.append(ReviewTask(state: state))
                continue
            }

            if let nonAdjacentIndex = pending.firstIndex(where: { candidate in
                result.last?.wordID != candidate.wordID
            }) {
                let state = pending.remove(at: nonAdjacentIndex)
                result.append(ReviewTask(state: state))
                continue
            }

            // Only the opposite direction of the immediately previous word is
            // left. Defer it to the next session instead of leaking the answer.
            break
        }

        return result
    }

    static func buildExtraPracticeQueue(
        from states: [ReviewStateSnapshot],
        limit: Int?,
        includeAll: Bool = false
    ) -> [ReviewTask] {
        let ranked = states
            .filter { includeAll || $0.formalUnknownCount > 0 }
            .sorted { lhs, rhs in
                let lhsWeakness = WeaknessScorer.score(lhs)
                let rhsWeakness = WeaknessScorer.score(rhs)
                if lhsWeakness != rhsWeakness { return lhsWeakness > rhsWeakness }
                if lhs.extraPracticeAttempts != rhs.extraPracticeAttempts {
                    return lhs.extraPracticeAttempts < rhs.extraPracticeAttempts
                }
                if lhs.normalizedEnglish != rhs.normalizedEnglish {
                    return lhs.normalizedEnglish < rhs.normalizedEnglish
                }
                if lhs.direction.rawValue != rhs.direction.rawValue {
                    return lhs.direction.rawValue < rhs.direction.rawValue
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        let maximum = limit.flatMap { $0 > 0 ? $0 : nil } ?? ranked.count
        return arrangeAvoidingOppositeDirections(ranked, limit: maximum)
    }

    static func insertingRetry(
        for completedTask: ReviewTask,
        attempt: Int,
        into remainingQueue: [ReviewTask]
    ) -> [ReviewTask] {
        guard attempt >= 1, attempt <= maximumRetryCount else { return remainingQueue }
        guard !remainingQueue.isEmpty else { return remainingQueue }

        var queue = remainingQueue
        let retry = ReviewTask(
            state: completedTask.state,
            kind: .sameSessionRetry(attempt: attempt)
        )

        if queue.count >= 5 {
            let preferredUpperBound = min(10, queue.count)
            for index in 5...preferredUpperBound {
                if canInsert(wordID: retry.wordID, at: index, in: queue) {
                    queue.insert(retry, at: index)
                    return queue
                }
            }
        }

        if queue.count >= 2 {
            for index in 1...queue.count {
                if canInsert(wordID: retry.wordID, at: index, in: queue) {
                    queue.insert(retry, at: index)
                    return queue
                }
            }
        }

        if queue.last?.wordID != retry.wordID {
            queue.append(retry)
        }
        return queue
    }

    private static func compare(
        _ lhs: ReviewStateSnapshot,
        _ rhs: ReviewStateSnapshot,
        today: Date,
        calendar: Calendar
    ) -> Bool {
        let lhsOverdue = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: lhs.nextReviewDate),
            to: today
        ).day ?? 0
        let rhsOverdue = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: rhs.nextReviewDate),
            to: today
        ).day ?? 0

        if lhsOverdue != rhsOverdue { return lhsOverdue > rhsOverdue }

        let lhsWeakness = WeaknessScorer.score(lhs)
        let rhsWeakness = WeaknessScorer.score(rhs)
        if lhsWeakness != rhsWeakness { return lhsWeakness > rhsWeakness }
        if lhs.formalAttempts != rhs.formalAttempts {
            return lhs.formalAttempts < rhs.formalAttempts
        }
        if lhs.normalizedEnglish != rhs.normalizedEnglish {
            return lhs.normalizedEnglish < rhs.normalizedEnglish
        }
        if lhs.direction.rawValue != rhs.direction.rawValue {
            return lhs.direction.rawValue < rhs.direction.rawValue
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func arrangeAvoidingOppositeDirections(
        _ ranked: [ReviewStateSnapshot],
        limit: Int
    ) -> [ReviewTask] {
        var pending = ranked
        var result: [ReviewTask] = []

        while !pending.isEmpty, result.count < limit {
            if let preferredIndex = pending.firstIndex(where: { isPreferred($0, after: result) }) {
                result.append(ReviewTask(state: pending.remove(at: preferredIndex)))
            } else if let nonAdjacentIndex = pending.firstIndex(where: {
                result.last?.wordID != $0.wordID
            }) {
                result.append(ReviewTask(state: pending.remove(at: nonAdjacentIndex)))
            } else {
                break
            }
        }
        return result
    }

    private static func isPreferred(
        _ candidate: ReviewStateSnapshot,
        after tasks: [ReviewTask]
    ) -> Bool {
        !tasks.suffix(preferredOppositeDirectionGap).contains {
            $0.wordID == candidate.wordID
        }
    }

    private static func canInsert(
        wordID: UUID,
        at index: Int,
        in queue: [ReviewTask]
    ) -> Bool {
        let previousMatches = index > 0 && queue[index - 1].wordID == wordID
        let nextMatches = index < queue.count && queue[index].wordID == wordID
        return !previousMatches && !nextMatches
    }
}
