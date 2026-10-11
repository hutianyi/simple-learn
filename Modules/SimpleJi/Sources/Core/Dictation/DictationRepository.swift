import CoreData
import Foundation

final class DictationRepository {
    enum DictationError: LocalizedError {
        case wordMissing
        case dayMissing
        case invalidPhase
        case answerChanged
        case alreadyAnswered

        var errorDescription: String? {
            switch self {
            case .wordMissing: return "找不到这个单词。"
            case .dayMissing: return "找不到今天的默写任务。"
            case .invalidPhase: return "当前训练阶段已变化，请重新打开默写。"
            case .answerChanged: return "这个单词的英文答案已修改，请重新打开默写。"
            case .alreadyAnswered: return "这道题已经提交。"
            }
        }
    }

    private let container: NSPersistentContainer
    private let calendar: Calendar
    private let baselineDailyLimit = 50

    init(container: NSPersistentContainer, calendar: Calendar = DictationEligibility.calendar()) {
        self.container = container
        self.calendar = calendar
    }

    func initialCopyQueue(
        campaign: BaselineCampaignSnapshot? = nil,
        masteredTerms: Set<String> = [],
        now: Date = Date(), dailyNewLimit: Int = 5
    ) async throws -> [InitialCopyPrompt] {
        let context = makeContext()
        let calendar = self.calendar
        let baselineIDs = Set(campaign?.selectedWordIDs ?? [])
        return try await context.perform {
            let request = WordEntity.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: true),
                NSSortDescriptor(key: "importPosition", ascending: true)
            ]
            request.relationshipKeyPathsForPrefetching = ["events", "dictationState"]
            let words = try context.fetch(request)
            let stateRequest = DictationStateEntity.fetchRequest()
            let existing = try context.fetch(stateRequest)
            let pendingBaseline = baselineIDs.subtracting(try Self.completedBaselineIDs(in: context))
            var startedToday = existing.filter {
                DictationEligibility.dayKey(for: $0.initialCopyStartedAt, calendar: calendar)
                    == DictationEligibility.dayKey(for: now, calendar: calendar)
            }.count
            var result: [InitialCopyPrompt] = []

            for word in words {
                guard !masteredTerms.contains(EnglishNormalizer.normalize(word.english)) else { continue }
                guard !pendingBaseline.contains(word.id) else { continue }
                let events = word.events.compactMap { event -> DictationCardEvent? in
                    guard let direction = ReviewDirection(rawValue: event.direction),
                          let answer = ReviewResult(rawValue: event.result),
                          let mode = PracticeMode(rawValue: event.practiceMode) else { return nil }
                    return DictationCardEvent(
                        reviewedAt: event.reviewedAt,
                        direction: direction,
                        result: answer,
                        mode: mode,
                        isSameSessionRetry: event.isSameSessionRetry,
                        englishSnapshot: event.wordEnglishSnapshot
                    )
                }
                guard DictationEligibility.qualifies(
                    events: events, currentEnglish: word.english, calendar: calendar
                ) else { continue }

                var state = word.dictationState
                if let current = state,
                   current.englishVersion != DictationAnswerMatcher.normalize(word.english) {
                    Self.resetForChangedAnswer(current, word: word, now: now)
                }
                if state == nil {
                    guard startedToday < dailyNewLimit else { continue }
                    state = Self.newState(for: word, in: context, now: now)
                    startedToday += 1
                }
                guard let state,
                      state.initialCopyCompletedAt == nil,
                      state.totalFormal == 0 else { continue }
                result.append(InitialCopyPrompt(
                    wordID: word.id,
                    english: word.english,
                    chinese: word.chinese,
                    completedCopies: Int(state.initialCopyCount),
                    consecutiveFailures: try Self.initialCopyFailures(for: word, state: state, in: context),
                    keyboardAllowed: try Self.initialKeyboardAllowed(for: word, state: state, in: context)
                ))
            }
            if context.hasChanges { try context.save() }
            return result
        }
    }

    func recordInitialCopy(wordID: UUID, recognized: String, viaKeyboard: Bool = false,
                           explicitReason: DictationFailureReason? = nil, now: Date = Date()) async throws -> InitialCopyPrompt {
        let context = makeContext()
        let calendar = self.calendar
        return try await context.perform {
            let word = try Self.fetchWord(wordID, in: context)
            guard let state = word.dictationState,
                  state.initialCopyCompletedAt == nil else { throw DictationError.invalidPhase }
            let failures = try Self.initialCopyFailures(for: word, state: state, in: context)
            guard try !viaKeyboard || Self.initialKeyboardAllowed(for: word, state: state, in: context) else {
                throw DictationError.invalidPhase
            }
            let correct = explicitReason == nil && DictationAnswerMatcher.matches(recognized, answer: word.english)
            if correct {
                state.initialCopyCount = viaKeyboard ? 3 : state.initialCopyCount + 1
                if state.initialCopyCount >= 3 {
                    state.initialCopyCompletedAt = now
                    state.fsrsCardData = try SRSScheduler.encodeCard(SRSScheduler.emptyCard(due: now))
                    state.formalNotBefore = DictationEligibility.nextDay(after: now, calendar: calendar)
                    state.nextReviewDate = state.formalNotBefore
                }
            }
            Self.recordEvent(
                in: context, wordID: wordID, dayKey: DictationEligibility.dayKey(for: now, calendar: calendar),
                kind: viaKeyboard ? "initialCopyKeyboard" : "initialCopy", correct: correct, reason: explicitReason, recognized: recognized,
                english: word.english, chinese: word.chinese, now: now,
                round: viaKeyboard || correct ? 0 : failures + 1
            )
            try StudyCompletionRepository.refresh(in: context, now: now, calendar: calendar)
            try context.save()
            return InitialCopyPrompt(
                wordID: word.id,
                english: word.english,
                chinese: word.chinese,
                completedCopies: Int(state.initialCopyCount),
                consecutiveFailures: try Self.initialCopyFailures(for: word, state: state, in: context),
                keyboardAllowed: try Self.initialKeyboardAllowed(for: word, state: state, in: context)
            )
        }
    }

    func baselineCandidates() async throws -> [BaselineCandidate] {
        let context = makeContext()
        return try await context.perform {
            let request = WordEntity.fetchRequest()
            request.relationshipKeyPathsForPrefetching = ["dictationState"]
            return try context.fetch(request)
                .filter { ($0.dictationState?.totalFormal ?? 0) == 0 }
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    if $0.importPosition != $1.importPosition {
                        return $0.importPosition < $1.importPosition
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .map {
                    BaselineCandidate(id: $0.id, english: $0.english, chinese: $0.chinese,
                                      createdAt: $0.createdAt, importPosition: $0.importPosition)
                }
        }
    }

    func automaticBaselineCampaign(
        masteredTerms: Set<String> = [], now: Date = Date()
    ) async throws -> BaselineCampaignSnapshot {
        let startOfToday = calendar.startOfDay(for: now)
        let oldWordIDs = try await baselineCandidates()
            .filter {
                $0.createdAt < startOfToday
                    && !masteredTerms.contains(EnglishNormalizer.normalize($0.english))
            }
            .map(\.id)
        return BaselineCampaignSnapshot(selectedWordIDs: oldWordIDs, activatedAt: now)
    }

    func baselineProgress(
        for campaign: BaselineCampaignSnapshot, masteredTerms: Set<String> = []
    ) async throws -> BaselineProgress {
        let context = makeContext()
        return try await context.perform {
            let existing = Set(try context.fetch(WordEntity.fetchRequest())
                .filter { !masteredTerms.contains(EnglishNormalizer.normalize($0.english)) }
                .map(\.id))
            let selected = Set(campaign.selectedWordIDs).intersection(existing)
            let request = DictationEventEntity.fetchRequest()
            request.predicate = NSPredicate(format: "kind == %@", "baselineFormal")
            let completed = Set(try context.fetch(request).map(\.wordID)).intersection(selected)
            return BaselineProgress(total: selected.count, completed: completed.count)
        }
    }

    func loadOrCreateDay(
        limit: Int, campaign: BaselineCampaignSnapshot? = nil,
        masteredTerms: Set<String> = [],
        now: Date = Date()
    ) async throws -> DictationDay {
        let context = makeContext()
        let calendar = self.calendar
        let baselineDailyLimit = self.baselineDailyLimit
        return try await context.perform {
            try StudyCompletionRepository.refresh(in: context, now: now, calendar: calendar,
                scope: StudyCompletionScope(baselineWordIDs: campaign.map { Set($0.selectedWordIDs) },
                    masteredTerms: masteredTerms))
            if context.hasChanges { try context.save() }
            let today = DictationEligibility.dayKey(for: now, calendar: calendar)
            let allDays = try context.fetch(DictationDayEntity.fetchRequest())
                .filter { !$0.dayKey.hasSuffix("#repair") }
                .sorted { $0.createdAt < $1.createdAt }
            for entity in allDays where entity.phase != DictationPhase.complete.rawValue {
                var day = try Self.snapshot(entity)
                let savedDay = day
                day.items.removeAll {
                    masteredTerms.contains(EnglishNormalizer.normalize($0.english))
                }
                // Restored queues can retain an old phase after all corrections have passed.
                switch day.phase {
                case .firstPass where day.items.allSatisfy({ $0.formalResult != nil }):
                    day.phase = day.unresolved > 0 ? .firstPassSummary : .complete
                case .firstPassSummary where day.unresolved == 0:
                    day.phase = .complete
                default: break
                }
                Self.advanceRemediation(&day)
                if day != savedDay {
                    try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
                }
                if day.dayKey == today,
                   let index = Self.activeTimedIndex(in: day),
                   day.items[index].isWriting {
                    day.items[index].isWriting = false
                    day.items[index].remainingSeconds = 30
                    day.items[index].interruptionCount += 1
                    let item = day.items[index]
                    Self.recordEvent(
                        in: context, wordID: item.wordID, dayID: day.id, dayKey: day.dayKey,
                        kind: "interruption", correct: nil, recognized: nil,
                        english: item.english, chinese: item.chinese, now: now,
                        round: item.remediationRound
                    )
                    try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
                }
                if day.dayKey != today && day.phase == .firstPass {
                    day.items.removeAll { $0.formalResult == nil && !$0.awaitsVerification }
                    day.phase = day.items.contains(where: \.awaitsVerification) ? .firstPass
                        : (day.unresolved > 0 ? .firstPassSummary : .complete)
                    try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
                }
                if day.items.contains(where: \.isDeferred) {
                    for index in day.items.indices { day.items[index].deferred = nil }
                    Self.advanceRemediation(&day)
                    try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
                }
                if day.phase != .complete {
                    if day.dayKey != today { return day }
                    break
                }
            }
            let wordRequest = WordEntity.fetchRequest()
            wordRequest.relationshipKeyPathsForPrefetching = ["dictationState", "events"]
            let words = try context.fetch(wordRequest)
            let wordsByID = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
            let completedBaseline = try Self.completedBaselineIDs(in: context)
            let baselinePending = Set(campaign?.selectedWordIDs ?? [])
                .subtracting(completedBaseline)
                .filter { id in
                    guard let word = wordsByID[id] else { return false }
                    return (word.dictationState?.totalFormal ?? 0) == 0
                        && !masteredTerms.contains(EnglishNormalizer.normalize(word.english))
                }
            let baselineLimit = limit == 0 ? baselineDailyLimit : min(limit, baselineDailyLimit)
            let dayLimit = baselinePending.isEmpty ? limit : baselineLimit

            let tomorrow = DictationEligibility.nextDay(after: now, calendar: calendar)
            let candidates = words.compactMap { word -> (word: WordEntity, due: Date, priority: Int, isNew: Bool)? in
                guard !baselinePending.contains(word.id),
                      !masteredTerms.contains(EnglishNormalizer.normalize(word.english)) else { return nil }
                if DictationEligibility.canStartDirectly(word: word, now: now, calendar: calendar) {
                    return (word, now, 2, true)
                }
                guard let state = word.dictationState,
                      state.englishVersion == DictationAnswerMatcher.normalize(word.english),
                      (state.initialCopyCompletedAt != nil || state.totalFormal > 0),
                      let due = state.nextReviewDate,
                      due < tomorrow,
                      (state.formalNotBefore ?? .distantPast) <= now,
                      state.lastFormalDay != today else { return nil }
                let priority = due < calendar.startOfDay(for: now) ? 0 : (state.totalFormal == 0 ? 2 : 1)
                return (word, due, priority, false)
            }.sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                if $0.due != $1.due { return $0.due < $1.due }
                if $0.word.createdAt != $1.word.createdAt { return $0.word.createdAt < $1.word.createdAt }
                if $0.word.importPosition != $1.word.importPosition { return $0.word.importPosition < $1.word.importPosition }
                return $0.word.id.uuidString < $1.word.id.uuidString
            }
            let completionRequest = StudyCompletionDayEntity.fetchRequest()
            completionRequest.predicate = NSPredicate(format: "dayKey == %@", today)
            let completedToday = try context.fetch(completionRequest).first.map {
                try JSONDecoder().decode(StudyCompletionDay.self, from: $0.snapshotData).isComplete
            } ?? false
            let newItems: (Set<UUID>, Int, Int) -> [DictationItem] = { existingIDs, slots, alreadyStarted in
                var newSlots = max(0, DictationEligibility.dailyNewWordLimit - alreadyStarted)
                return Array(candidates.filter { candidate in
                    guard !existingIDs.contains(candidate.word.id) else { return false }
                    if candidate.isNew {
                        guard newSlots > 0 else { return false }
                        newSlots -= 1
                    }
                    return true
                }.prefix(slots)).map {
                    var item = DictationItem(wordID: $0.word.id, english: $0.word.english, chinese: $0.word.chinese)
                    if $0.isNew { item.isNewWord = true }
                    return item
                }
            }
            if let existing = allDays.first(where: { $0.dayKey == today }) {
                var day = try Self.snapshot(existing)
                let hasProgress: (DictationItem) -> Bool = {
                    $0.formalResult != nil || $0.awaitsVerification || $0.isWriting
                        || $0.remainingSeconds < 30 || $0.recognitionFailures > 0
                        || $0.interruptionCount > 0
                }
                if !baselinePending.isEmpty || day.items.contains(where: \.belongsToBaseline) {
                    guard day.limit != baselineLimit || (day.phase == .complete && !baselinePending.isEmpty) else { return day }
                    day.limit = baselineLimit
                    var slots = max(0, baselineLimit - day.items.filter(hasProgress).count)
                    day.items = day.items.filter { item in
                        if hasProgress(item) { return true }
                        guard slots > 0 else { return false }
                        slots -= 1
                        return true
                    }
                    let additions = Self.baselineItems(
                        campaign: campaign, wordsByID: wordsByID,
                        completed: completedBaseline,
                        excluding: Set(day.items.map(\.wordID)),
                        masteredTerms: masteredTerms, limit: slots
                    )
                    day.items.append(contentsOf: additions)
                    if day.items.contains(where: { $0.formalResult == nil }) {
                        day.phase = .firstPass
                    } else if day.unresolved == 0 {
                        day.phase = .complete
                    } else if day.phase == .firstPass || day.phase == .complete {
                        day.phase = .firstPassSummary
                    }
                    try Self.save(day, to: existing, now: now, in: context, calendar: self.calendar)
                    return day
                }
                // An empty preview may fill after card review; a finished task stays finished.
                guard day.limit != limit || (day.items.isEmpty && !completedToday && !candidates.isEmpty) else { return day }
                day.limit = limit
                let alreadyStarted = day.items.filter { $0.isNewWord == true }.count
                // Keep results and any question already attempted; only postpone untouched words.
                var slots = limit == 0 ? Int.max : max(0, limit - day.items.filter(hasProgress).count)
                day.items = day.items.filter { item in
                    if hasProgress(item) { return true }
                    guard slots > 0 else { return false }
                    slots -= 1
                    return true
                }
                let existingIDs = Set(day.items.map(\.wordID))
                day.items.append(contentsOf: newItems(existingIDs, slots, alreadyStarted))
                if day.items.contains(where: { $0.formalResult == nil }) {
                    day.phase = .firstPass
                } else if day.unresolved == 0 {
                    day.phase = .complete
                } else if day.phase == .firstPass || day.phase == .complete {
                    day.phase = .firstPassSummary
                }
                try Self.save(day, to: existing, now: now, in: context, calendar: self.calendar)
                return day
            }

            var items = Self.baselineItems(
                campaign: campaign, wordsByID: wordsByID,
                completed: completedBaseline,
                excluding: [], masteredTerms: masteredTerms,
                limit: baselinePending.isEmpty ? 0 : dayLimit
            )
            let regularSlots = baselinePending.isEmpty && !completedToday
                ? (limit == 0 ? Int.max : limit) : 0
            items.append(contentsOf: newItems([], regularSlots, 0))
            let day = DictationDay(
                id: UUID(), dayKey: today, timeZoneID: calendar.timeZone.identifier,
                limit: dayLimit, phase: items.isEmpty ? .complete : .firstPass,
                items: items, createdAt: now, updatedAt: now
            )
            let entity = DictationDayEntity(context: context)
            entity.id = day.id
            entity.dayKey = day.dayKey
            entity.timeZoneID = day.timeZoneID
            entity.limit = Int32(dayLimit)
            entity.createdAt = now
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            return day
        }
    }

    func beginRemediation(dayID: UUID, now: Date = Date()) async throws -> DictationDay {
        let context = makeContext()
        return try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard day.phase == .firstPassSummary else { throw DictationError.invalidPhase }
            day.phase = .remediationCopy
            Self.advanceRemediation(&day)
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            return day
        }
    }

    func repairDay(id: UUID, now: Date = Date()) async throws -> DictationDay {
        let context = makeContext()
        return try await context.perform {
            let day = try Self.snapshot(Self.fetchDay(id, in: context))
            guard day.dayKey == DictationEligibility.dayKey(for: now, calendar: self.calendar) + "#repair" else {
                throw StudyRepairRepository.RepairError.expired
            }
            return day
        }
    }

    func stageVerification(
        dayID: UUID, wordID: UUID, recognized: String?, now: Date = Date()
    ) async throws -> DictationDay {
        let context = makeContext()
        return try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard let index = Self.activeTimedIndex(in: day), day.items[index].wordID == wordID,
                  !day.items[index].awaitsVerification else { throw DictationError.invalidPhase }
            let word = try Self.fetchWord(wordID, in: context)
            guard DictationAnswerMatcher.normalize(word.english) == DictationAnswerMatcher.normalize(day.items[index].english) else {
                throw DictationError.answerChanged
            }
            guard !DictationAnswerMatcher.matches(recognized ?? "", answer: word.english) else {
                throw DictationError.invalidPhase
            }
            day.items[index].pendingHandwriting = recognized ?? ""
            day.items[index].isWriting = false
            let item = day.items[index]
            Self.recordEvent(in: context, wordID: wordID, dayID: day.id, dayKey: day.dayKey,
                             kind: "recognitionMismatch", correct: nil, recognized: recognized,
                             english: item.english, chinese: item.chinese, now: now,
                             remaining: item.remainingSeconds, round: item.remediationRound)
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            return day
        }
    }

    func beginKeyboardVerification(dayID: UUID, wordID: UUID, now: Date = Date()) async throws -> DictationDay {
        let context = makeContext()
        return try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard let index = Self.activeTimedIndex(in: day), day.items[index].wordID == wordID,
                  day.items[index].awaitsVerification else { throw DictationError.invalidPhase }
            if day.items[index].keyboardDeadline == nil {
                day.items[index].keyboardDeadline = now.addingTimeInterval(DictationKeyboardClock.duration)
                try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            }
            return day
        }
    }

    private static func verificationInput(
        item: DictationItem, recognized: String?, explicitReason: DictationFailureReason?,
        resolvingVerification: Bool, viaKeyboard: Bool, now: Date
    ) throws -> (text: String?, reason: DictationFailureReason?) {
        guard item.awaitsVerification == resolvingVerification, !viaKeyboard || resolvingVerification else {
            throw DictationError.invalidPhase
        }
        guard resolvingVerification else { return (recognized, explicitReason) }
        if viaKeyboard {
            guard let deadline = item.keyboardDeadline else { throw DictationError.invalidPhase }
            let reason = now >= deadline ? DictationFailureReason.timeout : explicitReason
            // A blank keyboard confirmation is an incorrect final answer, never an OCR retry.
            return (recognized, reason ?? (DictationAnswerMatcher.normalize(recognized ?? "").isEmpty ? .spelling : nil))
        }
        guard item.keyboardDeadline == nil else { throw DictationError.invalidPhase }
        return (item.pendingHandwriting,
                DictationAnswerMatcher.normalize(item.pendingHandwriting ?? "").isEmpty ? .recognition : .spelling)
    }

    private static func recordKeyboardVerification(
        item: DictationItem, day: DictationDay, input: String?, correct: Bool,
        reason: DictationFailureReason?, now: Date, in context: NSManagedObjectContext
    ) {
        Self.recordEvent(in: context, wordID: item.wordID, dayID: day.id, dayKey: day.dayKey,
                         kind: "keyboardVerification", correct: correct, reason: reason, recognized: input,
                         english: item.english, chinese: item.chinese, now: now,
                         remaining: item.keyboardDeadline.map { DictationKeyboardClock.remaining(until: $0, now: now) } ?? 0,
                         round: item.remediationRound)
    }

    func submitFormal(
        dayID: UUID,
        wordID: UUID,
        recognized: String?,
        explicitReason: DictationFailureReason? = nil,
        resolvingVerification: Bool = false, viaKeyboard: Bool = false,
        now: Date = Date()
    ) async throws -> DictationSubmission {
        let context = makeContext()
        let calendar = self.calendar
        return try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard day.phase == .firstPass,
                  let index = day.items.firstIndex(where: { $0.wordID == wordID && $0.formalResult == nil }) else {
                throw DictationError.alreadyAnswered
            }
            var item = day.items[index]
            let word = try Self.fetchWord(wordID, in: context)
            guard DictationAnswerMatcher.normalize(word.english)
                    == DictationAnswerMatcher.normalize(item.english) else {
                throw DictationError.answerChanged
            }
            guard day.isStreakRepair || word.dictationState?.lastFormalDay != day.dayKey else {
                throw DictationError.alreadyAnswered
            }

            let input = try Self.verificationInput(item: item, recognized: recognized, explicitReason: explicitReason,
                                                   resolvingVerification: resolvingVerification, viaKeyboard: viaKeyboard, now: now)
            let normalized = input.text.map(DictationAnswerMatcher.normalize) ?? ""
            if input.reason == nil && normalized.isEmpty && item.recognitionFailures == 0 {
                item.recognitionFailures = 1
                day.items[index] = item
                Self.recordEvent(
                    in: context, wordID: wordID, dayID: day.id, dayKey: day.dayKey,
                    kind: "recognitionRetry", correct: nil, recognized: recognized,
                    english: item.english, chinese: item.chinese, now: now,
                    remaining: item.remainingSeconds
                )
                try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
                return .retry(day)
            }
            let correct = input.reason == nil
                && !normalized.isEmpty
                && DictationAnswerMatcher.matches(normalized, answer: item.english)
            let reason: DictationFailureReason? = correct ? nil
                : input.reason ?? (normalized.isEmpty ? .recognition : .spelling)
            let state: DictationStateEntity
            if let existing = word.dictationState {
                state = existing
            } else if item.belongsToBaseline || item.isNewWord == true {
                state = Self.newState(for: word, in: context, now: now)
            } else {
                throw DictationError.answerChanged
            }
            let cardBefore = state.fsrsCardData
            let decision = day.isStreakRepair ? nil : try SRSScheduler.decision(
                cardData: state.fsrsCardData,
                answer: correct ? .known : .unknown,
                date: now
            )
            if let decision {
                state.fsrsCardData = decision.cardData
                state.nextReviewDate = decision.nextReviewDate
                state.lastFormalDay = day.dayKey
                state.lastResult = correct ? "correct" : "incorrect"
                state.totalFormal += 1
                if !correct {
                    state.formalNotBefore = DictationEligibility.nextDay(after: now, calendar: calendar)
                }
            }
            item.formalResult = correct
            if viaKeyboard {
                Self.recordKeyboardVerification(item: item, day: day, input: input.text, correct: correct, reason: reason, now: now, in: context)
            }
            item.formalInputMethod = viaKeyboard ? "keyboard" : "handwriting"
            item.pendingHandwriting = nil
            item.keyboardDeadline = nil
            item.isWriting = false
            item.formalReason = reason
            item.formalSubmittedAt = now
            day.items[index] = item
            Self.recordEvent(
                in: context, wordID: wordID, dayID: day.id, dayKey: day.dayKey,
                kind: day.isStreakRepair ? "repairFormal" : (item.belongsToBaseline ? "baselineFormal" : "formal"),
                correct: correct, reason: reason, recognized: input.text,
                english: item.english, chinese: item.chinese, now: now,
                remaining: item.remainingSeconds,
                fsrsBefore: day.isStreakRepair ? nil : cardBefore, fsrsAfter: decision?.cardData
            )
            if day.items.allSatisfy({ $0.formalResult != nil }) {
                day.phase = day.unresolved > 0 ? .firstPassSummary : .complete
            }
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            return .result(day, correct: correct, reason: reason)
        }
    }

    func recordRemediationCopy(
        dayID: UUID, wordID: UUID, recognized: String, viaKeyboard: Bool = false,
        explicitReason: DictationFailureReason? = nil, now: Date = Date()
    ) async throws -> DictationDay {
        let context = makeContext()
        return try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard day.phase == .remediationCopy,
                  let index = day.items.firstIndex(where: { $0.wordID == wordID && $0.needsRemediation }),
                  day.items[index].remediationCopyCount < 3 else { throw DictationError.invalidPhase }
            let word = try Self.fetchWord(wordID, in: context)
            guard DictationAnswerMatcher.normalize(word.english)
                    == DictationAnswerMatcher.normalize(day.items[index].english) else {
                throw DictationError.answerChanged
            }
            guard !day.items[index].isDeferred,
                  !viaKeyboard || day.items[index].allowsKeyboard else { throw DictationError.invalidPhase }
            let correct = explicitReason == nil && DictationAnswerMatcher.matches(recognized, answer: day.items[index].english)
            if correct {
                day.items[index].remediationCopyCount = viaKeyboard ? 3 : day.items[index].remediationCopyCount + 1
            }
            if !viaKeyboard {
                let failures = correct ? 0 : (day.items[index].consecutiveCopyFailures ?? 0) + 1
                day.items[index].consecutiveCopyFailures = failures
                if failures >= 3 { day.items[index].keyboardAllowed = true }
            }
            Self.recordEvent(
                in: context, wordID: wordID, dayID: day.id, dayKey: day.dayKey,
                kind: viaKeyboard ? "remediationCopyKeyboard" : "remediationCopy", correct: correct, reason: explicitReason, recognized: recognized,
                english: day.items[index].english, chinese: day.items[index].chinese,
                now: now, round: day.items[index].remediationRound
            )
            Self.advanceRemediation(&day)
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            return day
        }
    }

    func submitRetest(
        dayID: UUID, wordID: UUID, recognized: String?,
        explicitReason: DictationFailureReason? = nil,
        resolvingVerification: Bool = false, viaKeyboard: Bool = false, now: Date = Date()
    ) async throws -> DictationSubmission {
        let context = makeContext()
        let calendar = self.calendar
        return try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard day.phase == .retest,
                  let index = day.items.firstIndex(where: {
                      $0.wordID == wordID && $0.needsRemediation && !$0.retestAttempted && !$0.isDeferred && $0.remediationCopyCount >= 3
                  }) else { throw DictationError.invalidPhase }
            var item = day.items[index]
            let word = try Self.fetchWord(wordID, in: context)
            guard DictationAnswerMatcher.normalize(word.english)
                    == DictationAnswerMatcher.normalize(item.english) else {
                throw DictationError.answerChanged
            }
            let input = try Self.verificationInput(item: item, recognized: recognized, explicitReason: explicitReason,
                                                   resolvingVerification: resolvingVerification, viaKeyboard: viaKeyboard, now: now)
            let normalized = input.text.map(DictationAnswerMatcher.normalize) ?? ""
            if input.reason == nil && normalized.isEmpty && item.recognitionFailures == 0 {
                item.recognitionFailures = 1
                day.items[index] = item
                Self.recordEvent(
                    in: context, wordID: wordID, dayID: day.id, dayKey: day.dayKey,
                    kind: "recognitionRetry", correct: nil, recognized: recognized,
                    english: item.english, chinese: item.chinese, now: now,
                    remaining: item.remainingSeconds, round: item.remediationRound
                )
                try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
                return .retry(day)
            }
            let correct = input.reason == nil
                && !normalized.isEmpty
                && DictationAnswerMatcher.matches(normalized, answer: item.english)
            let reason: DictationFailureReason? = correct ? nil
                : input.reason ?? (normalized.isEmpty ? .recognition : .spelling)
            item.retestAttempted = true
            if viaKeyboard {
                Self.recordKeyboardVerification(item: item, day: day, input: input.text, correct: correct, reason: reason, now: now, in: context)
            }
            item.retestInputMethod = viaKeyboard ? "keyboard" : "handwriting"
            item.pendingHandwriting = nil
            item.keyboardDeadline = nil
            item.isWriting = false
            item.recognitionFailures = 0
            if correct {
                item.remediationPassed = true
                if !day.isStreakRepair, let state = word.dictationState {
                    state.formalNotBefore = DictationEligibility.nextDay(after: now, calendar: calendar)
                }
            } else {
                item.remediationCopyCount = 0
                item.remediationRound += 1
                item.consecutiveCopyFailures = 0
                item.remainingSeconds = 30
            }
            day.items[index] = item
            Self.recordEvent(
                in: context, wordID: wordID, dayID: day.id, dayKey: day.dayKey,
                kind: "retest", correct: correct, reason: reason, recognized: input.text,
                english: item.english, chinese: item.chinese, now: now,
                remaining: item.remainingSeconds, round: item.remediationRound
            )
            Self.advanceRemediation(&day)
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            return .result(day, correct: correct, reason: reason)
        }
    }

    func deferRemediation(dayID: UUID, wordID: UUID, now: Date = Date()) async throws -> DictationDay {
        let context = makeContext()
        return try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard day.phase == .remediationCopy || day.phase == .retest,
                  let index = day.items.firstIndex(where: { $0.wordID == wordID && $0.needsRemediation && !$0.isDeferred }) else {
                throw DictationError.invalidPhase
            }
            day.items[index].deferred = true
            day.items[index].isWriting = false
            let item = day.items[index]
            Self.recordEvent(in: context, wordID: wordID, dayID: day.id, dayKey: day.dayKey,
                             kind: "deferred", correct: nil, recognized: nil,
                             english: item.english, chinese: item.chinese, now: now, round: item.remediationRound)
            Self.advanceRemediation(&day)
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
            return day
        }
    }

    private static func advanceRemediation(_ day: inout DictationDay) {
        guard day.phase == .remediationCopy || day.phase == .retest else { return }
        if day.unresolved == 0 { day.phase = .complete; return }
        let runnable = day.items.filter { $0.needsRemediation && !$0.isDeferred }
        guard !runnable.isEmpty else { return }
        if day.phase == .retest && runnable.contains(where: { !$0.retestAttempted && $0.remediationCopyCount >= 3 }) { return }
        if runnable.contains(where: { $0.remediationCopyCount < 3 }) {
            day.phase = .remediationCopy
            for index in day.items.indices where day.items[index].needsRemediation && !day.items[index].isDeferred {
                day.items[index].retestAttempted = false
            }
        } else {
            day.phase = .retest
            for index in day.items.indices where day.items[index].needsRemediation && !day.items[index].isDeferred {
                day.items[index].remainingSeconds = 30
                day.items[index].recognitionFailures = 0
            }
        }
    }

    private static func initialCopyEvents(for word: WordEntity, state: DictationStateEntity,
                                          in context: NSManagedObjectContext) throws -> [DictationEventEntity] {
        let request = DictationEventEntity.fetchRequest()
        request.predicate = NSPredicate(format: "wordID == %@ AND kind == %@ AND submittedAt >= %@",
                                        word.id as CVarArg, "initialCopy", state.initialCopyStartedAt as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "submittedAt", ascending: false)]
        return try context.fetch(request).filter {
            DictationAnswerMatcher.normalize($0.answerSnapshot) == state.englishVersion
        }
    }

    private static func initialCopyFailures(for word: WordEntity, state: DictationStateEntity,
                                            in context: NSManagedObjectContext) throws -> Int {
        let events = try initialCopyEvents(for: word, state: state, in: context)
        return events.prefix(while: { $0.result == "incorrect" }).count
    }

    private static func initialKeyboardAllowed(for word: WordEntity, state: DictationStateEntity,
                                               in context: NSManagedObjectContext) throws -> Bool {
        let events = try initialCopyEvents(for: word, state: state, in: context)
        return events.contains { $0.round >= 3 } || events.prefix(while: { $0.result == "incorrect" }).count >= 3
    }

    private static func recordEvent(
        in context: NSManagedObjectContext, wordID: UUID,
        dayID: UUID? = nil, dayKey: String,
        kind: String, correct: Bool?, reason: DictationFailureReason? = nil,
        recognized: String?, english: String, chinese: String, now: Date,
        remaining: Double = 0, round: Int = 0,
        fsrsBefore: Data? = nil, fsrsAfter: Data? = nil
    ) {
        let event = DictationEventEntity(context: context)
        event.id = UUID()
        event.wordID = wordID
        event.dayID = dayID
        event.dayKey = dayKey
        event.kind = kind
        event.formalKey = (kind == "formal" || kind == "baselineFormal")
            ? "\(dayKey)|\(wordID.uuidString)" : nil
        event.result = correct.map { $0 ? "correct" : "incorrect" } ?? "none"
        event.reason = reason?.rawValue
        event.recognizedText = recognized
        event.answerSnapshot = english
        event.chineseSnapshot = chinese
        event.submittedAt = now
        event.remainingSeconds = remaining
        event.round = Int16(clamping: round)
        event.fsrsBefore = fsrsBefore
        event.fsrsAfter = fsrsAfter
    }

    private func makeContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        return context
    }

    func setTimerState(
        dayID: UUID, wordID: UUID, remaining: Double, isWriting: Bool,
        now: Date = Date()
    ) async throws {
        let context = makeContext()
        try await context.perform {
            let entity = try Self.fetchDay(dayID, in: context)
            var day = try Self.snapshot(entity)
            guard let index = Self.activeTimedIndex(in: day),
                  day.items[index].wordID == wordID else { return }
            day.items[index].remainingSeconds = min(30, max(0, remaining))
            day.items[index].isWriting = isWriting
            try Self.save(day, to: entity, now: now, in: context, calendar: self.calendar)
        }
    }

    private static func activeTimedIndex(in day: DictationDay) -> Int? {
        switch day.phase {
        case .firstPass:
            return day.items.firstIndex { $0.formalResult == nil }
        case .retest:
            return day.items.firstIndex { $0.needsRemediation && !$0.retestAttempted && !$0.isDeferred && $0.remediationCopyCount >= 3 }
        case .firstPassSummary, .remediationCopy, .complete:
            return nil
        }
    }

    private static func completedBaselineIDs(in context: NSManagedObjectContext) throws -> Set<UUID> {
        let request = DictationEventEntity.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %@", "baselineFormal")
        return Set(try context.fetch(request).map(\.wordID))
    }

    private static func baselineItems(
        campaign: BaselineCampaignSnapshot?, wordsByID: [UUID: WordEntity],
        completed: Set<UUID>, excluding: Set<UUID>,
        masteredTerms: Set<String>, limit: Int
    ) -> [DictationItem] {
        guard let campaign, limit > 0 else { return [] }
        return Array(campaign.selectedWordIDs.compactMap { id -> DictationItem? in
            guard !completed.contains(id), !excluding.contains(id),
                  let word = wordsByID[id],
                  !masteredTerms.contains(EnglishNormalizer.normalize(word.english)),
                  (word.dictationState?.totalFormal ?? 0) == 0 else { return nil }
            var item = DictationItem(wordID: id, english: word.english, chinese: word.chinese)
            item.isBaseline = true
            return item
        }.prefix(limit))
    }

    private static func newState(
        for word: WordEntity, in context: NSManagedObjectContext, now: Date
    ) -> DictationStateEntity {
        let state = DictationStateEntity(context: context)
        state.id = UUID()
        state.wordID = word.id
        state.word = word
        state.englishVersion = DictationAnswerMatcher.normalize(word.english)
        state.initialCopyCount = 0
        state.initialCopyStartedAt = now
        state.totalFormal = 0
        return state
    }

    static func resetForChangedAnswer(_ state: DictationStateEntity, word: WordEntity, now: Date) {
        state.englishVersion = DictationAnswerMatcher.normalize(word.english)
        state.initialCopyCount = 0
        state.initialCopyStartedAt = now
        state.initialCopyCompletedAt = nil
        state.fsrsCardData = nil
        state.nextReviewDate = nil
        state.formalNotBefore = nil
        state.lastFormalDay = nil
        state.totalFormal = 0
        state.lastResult = nil
    }

    static func reconcileTasks(
        for wordID: UUID, preservingHistory: Bool,
        in context: NSManagedObjectContext
    ) throws {
        if !preservingHistory {
            let events = DictationEventEntity.fetchRequest()
            events.predicate = NSPredicate(format: "wordID == %@", wordID as CVarArg)
            for event in try context.fetch(events) { context.delete(event) }
        }
        for entity in try context.fetch(DictationDayEntity.fetchRequest()) {
            var items = try JSONDecoder().decode([DictationItem].self, from: entity.tasksData)
            let previousCount = items.count
            if preservingHistory {
                items.removeAll { $0.wordID == wordID && $0.formalResult == nil }
                for index in items.indices where items[index].wordID == wordID {
                    items[index].remediationPassed = true
                }
            } else {
                items.removeAll { $0.wordID == wordID }
            }
            guard items.count != previousCount || items.contains(where: { $0.wordID == wordID }) else {
                continue
            }
            if items.isEmpty || items.allSatisfy({ !$0.needsRemediation && $0.formalResult != nil }) {
                entity.phase = DictationPhase.complete.rawValue
            } else if entity.phase == DictationPhase.firstPass.rawValue,
                      items.allSatisfy({ $0.formalResult != nil }) {
                entity.phase = DictationPhase.firstPassSummary.rawValue
            } else if entity.phase == DictationPhase.retest.rawValue,
                      items.filter(\.needsRemediation).allSatisfy(\.retestAttempted) {
                entity.phase = DictationPhase.remediationCopy.rawValue
                for index in items.indices where items[index].needsRemediation {
                    items[index].retestAttempted = false
                    items[index].remediationCopyCount = 0
                }
            }
            entity.tasksData = try JSONEncoder().encode(items)
            entity.updatedAt = Date()
        }
    }

    private static func fetchWord(_ id: UUID, in context: NSManagedObjectContext) throws -> WordEntity {
        let request = WordEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let word = try context.fetch(request).first else { throw DictationError.wordMissing }
        return word
    }

    private static func fetchDay(_ id: UUID, in context: NSManagedObjectContext) throws -> DictationDayEntity {
        let request = DictationDayEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let day = try context.fetch(request).first else { throw DictationError.dayMissing }
        return day
    }

    private static func snapshot(_ entity: DictationDayEntity) throws -> DictationDay {
        DictationDay(
            id: entity.id,
            dayKey: entity.dayKey,
            timeZoneID: entity.timeZoneID,
            limit: Int(entity.limit),
            phase: DictationPhase(rawValue: entity.phase) ?? .complete,
            items: try JSONDecoder().decode([DictationItem].self, from: entity.tasksData),
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt
        )
    }

    private static func save(
        _ day: DictationDay, to entity: DictationDayEntity, now: Date,
        in context: NSManagedObjectContext, calendar: Calendar
    ) throws {
        if day.isStreakRepair {
            guard day.dayKey == DictationEligibility.dayKey(for: now, calendar: calendar) + "#repair" else {
                throw DictationError.invalidPhase
            }
        }
        entity.limit = Int32(day.limit)
        entity.phase = day.phase.rawValue
        entity.tasksData = try JSONEncoder().encode(day.items)
        entity.updatedAt = now
        try StudyCompletionRepository.refresh(in: context, now: now, calendar: calendar)
        try context.save()
    }
}
