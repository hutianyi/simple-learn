import CoreData
import Foundation
import StudyShell

struct StudyRepairOffer: Identifiable {
    let todayKey: String
    let plan: StudyRepairPlan
    let normalCardCount: Int
    var id: String { todayKey }

    var message: String {
        return "你之前已经连续完成了 \(plan.previousStreak) 天！\n昨天还没完成，要把连续记录接回来吗？\n今天待复习卡片 \(normalCardCount) 张，默写按设置的每日上限安排，错词照常订正。选择补上不会额外增加学习量。\n跟着这一轮完成今天的任务，就能补上昨天的打卡。主动结束或过了今天，这次机会就结束。"
    }
}

final class StudyRepairRepository {
    enum RepairError: LocalizedError {
        case expired, unavailable
        var errorDescription: String? {
            switch self {
            case .expired: return "今天的补学机会已经结束，请重新开始今天的学习。"
            case .unavailable: return "学习任务已变化，请重新进入后再开始。"
            }
        }
    }
    private let container: NSPersistentContainer
    private let calendar: Calendar

    init(container: NSPersistentContainer, calendar: Calendar = .current) {
        self.container = container
        self.calendar = calendar
    }

    func prepare(now: Date = Date()) async throws -> StudyRepairOffer? {
        let states = try await ReviewRepository(container: container, calendar: calendar).allStates()
        let context = container.newBackgroundContext()
        let calendar = self.calendar
        return try await context.perform {
            let todayKey = DictationEligibility.dayKey(for: now, calendar: calendar)
            let records = try context.fetch(StudyCompletionDayEntity.fetchRequest()).map {
                try JSONDecoder().decode(StudyCompletionDay.self, from: $0.snapshotData)
            }
            // A fresh entry never silently resumes an accepted one-sitting attempt.
            if records.first(where: { $0.dayKey == todayKey })?.repair?.status == .accepted {
                try Self.update(in: context, dayKey: todayKey, now: now, calendar: calendar) { $0.repair?.status = .abandoned }
                return nil
            }
            let history = try Self.completedKeys(in: context, records: records, now: now, calendar: calendar)
            let handled = Set(records.compactMap { $0.repair?.yesterdayKey })
            guard let offer = OneDayStreakRepair.offer(completedKeys: history, handledKeys: handled,
                now: now, calendar: calendar) else { return nil }
            let due = states.filter { $0.nextReviewDate < DictationEligibility.nextDay(after: now, calendar: calendar) }
            let plan = StudyRepairPlan(yesterdayKey: offer.yesterdayKey, previousStreak: offer.previousStreak,
                extraCardIDs: [], cardsComplete: true,
                dictationComplete: true, status: .accepted)
            guard !due.isEmpty || records.first(where: { $0.dayKey == todayKey })?.dictationComplete == false
                else { return nil }
            return StudyRepairOffer(todayKey: todayKey, plan: plan, normalCardCount: due.count)
        }
    }

    func decide(_ offer: StudyRepairOffer, accepted: Bool, now: Date = Date()) async throws {
        let context = container.newBackgroundContext()
        let calendar = self.calendar
        try await context.perform {
            guard offer.todayKey == DictationEligibility.dayKey(for: now, calendar: calendar) else { throw RepairError.expired }
            let records = try context.fetch(StudyCompletionDayEntity.fetchRequest()).map {
                try JSONDecoder().decode(StudyCompletionDay.self, from: $0.snapshotData)
            }
            let keys = try Self.completedKeys(in: context, records: records, now: now, calendar: calendar)
            guard let eligible = OneDayStreakRepair.offer(completedKeys: keys,
                handledKeys: Set(records.compactMap { $0.repair?.yesterdayKey }), now: now, calendar: calendar),
                eligible.yesterdayKey == offer.plan.yesterdayKey else { throw RepairError.unavailable }
            var plan = offer.plan
            plan.status = accepted ? .accepted : .declined
            try Self.update(in: context, dayKey: offer.todayKey, now: now, calendar: calendar) { $0.repair = plan }
        }
    }

    func today(now: Date = Date()) async throws -> StudyCompletionDay {
        let context = container.newBackgroundContext()
        return try await context.perform {
            try StudyCompletionRepository.refresh(in: context, now: now, calendar: self.calendar)
            if context.hasChanges { try context.save() }
            let key = DictationEligibility.dayKey(for: now, calendar: self.calendar)
            let entity = try context.fetch(StudyCompletionDayEntity.fetchRequest()).first { $0.dayKey == key }
            guard let entity else { throw RepairError.unavailable }
            return try JSONDecoder().decode(StudyCompletionDay.self, from: entity.snapshotData)
        }
    }

    func finishCards(dayKey: String, now: Date = Date()) async throws {
        let context = container.newBackgroundContext()
        try await context.perform {
            guard dayKey == DictationEligibility.dayKey(for: now, calendar: self.calendar) else { throw RepairError.expired }
            let sessions = Set(try context.fetch(StudySessionEntity.fetchRequest()).filter {
                $0.completed && $0.mode == PracticeMode.extraPractice.rawValue
                    && DictationEligibility.dayKey(for: $0.startedAt, calendar: self.calendar) == dayKey
            }.map(\.id))
            let answered = Set(try context.fetch(ReviewEventEntity.fetchRequest()).filter {
                sessions.contains($0.sessionID) && $0.practiceMode == PracticeMode.extraPractice.rawValue
                    && DictationEligibility.dayKey(for: $0.reviewedAt, calendar: self.calendar) == dayKey
            }.map { $0.reviewState.id })
            try Self.update(in: context, dayKey: dayKey, now: now, calendar: self.calendar) { day in
                guard let plan = day.repair, plan.status == .accepted,
                      Set(plan.extraCardIDs).isSubset(of: answered) else { throw RepairError.unavailable }
                day.repair?.cardsComplete = true
            }
        }
    }

    func abandon(dayKey: String, now: Date = Date()) async throws {
        let context = container.newBackgroundContext()
        try await context.perform {
            try Self.update(in: context, dayKey: dayKey, now: now, calendar: self.calendar) { day in
                if day.repair?.status == .accepted { day.repair?.status = .abandoned }
            }
        }
    }

    private static func update(in context: NSManagedObjectContext, dayKey: String, now: Date,
                               calendar: Calendar, mutation: (inout StudyCompletionDay) throws -> Void) throws {
        let entities = try context.fetch(StudyCompletionDayEntity.fetchRequest())
        guard let entity = entities.first(where: { $0.dayKey == dayKey }) else { throw RepairError.unavailable }
        var day = try JSONDecoder().decode(StudyCompletionDay.self, from: entity.snapshotData)
        try mutation(&day)
        if day.repair?.status == .accepted { day.completedAt = nil }
        entity.snapshotData = try JSONEncoder().encode(day)
        try StudyCompletionRepository.refresh(in: context, now: now, calendar: calendar)
        if context.hasChanges { try context.save() }
    }

    static func completedKeys(in context: NSManagedObjectContext, records: [StudyCompletionDay],
                              now: Date, calendar: Calendar) throws -> Set<String> {
        let cutoff = records.map(\.dayKey).min() ?? DictationEligibility.dayKey(for: now, calendar: calendar)
        let sessions = try context.fetch(StudySessionEntity.fetchRequest()).filter { $0.mode == PracticeMode.scheduled.rawValue }
        let events = try context.fetch(DictationEventEntity.fetchRequest())
        var historical = Set<String>()
        for day in try context.fetch(DictationDayEntity.fetchRequest()) where day.dayKey < cutoff && !day.dayKey.hasSuffix("#repair") {
            let dayCalendar = DictationEligibility.calendar(timeZone: TimeZone(identifier: day.timeZoneID) ?? calendar.timeZone)
            let items = try JSONDecoder().decode([DictationItem].self, from: day.tasksData)
            let retests = Dictionary(grouping: events.filter { $0.dayID == day.id && $0.kind == "retest" && $0.result == "correct" },
                by: \.wordID).mapValues { $0.map(\.submittedAt) }
            let cards = sessions.filter { DictationEligibility.dayKey(for: $0.startedAt, calendar: calendar) == day.dayKey }.map {
                StudyStreak.HistoricalSession(startedAt: $0.startedAt, finishedAt: $0.finishedAt,
                    completed: $0.completed, required: Int($0.baseTaskCount), answered: Int($0.formalAnswered))
            }
            if StudyStreak.historicalCardsFinished(sessions: cards, calendar: dayCalendar)
                && StudyStreak.historicalDictationFinished(dayKey: day.dayKey, phase: day.phase,
                    items: items, successfulRetests: retests, calendar: dayCalendar) { historical.insert(day.dayKey) }
        }
        return StudyStreak.completionKeys(completedDays: records, historicalKeys: historical, now: now, calendar: calendar)
    }
}
