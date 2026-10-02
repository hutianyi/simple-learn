import CoreData
import Foundation

enum BackupService {
    enum BackupError: LocalizedError {
        case wrongApp
        case unsupportedFormat(Int)
        case unsupportedSchema(Int)
        case invalidData(String)
        case brokenRelationship(String)

        var errorDescription: String? {
            switch self {
            case .wrongApp:
                return "这不是简单记 App 的备份文件。"
            case .unsupportedFormat(let version):
                return "不支持这个备份格式版本（\(version)）。"
            case .unsupportedSchema(let version):
                return "不支持这个数据库版本（\(version)）。"
            case .invalidData(let detail):
                return "备份内容不完整：\(detail)"
            case .brokenRelationship(let detail):
                return "备份中的数据关联无效：\(detail)"
            }
        }
    }

    static func makeEnvelope(
        container: NSPersistentContainer,
        settings: BackupSettings,
        appVersion: String
    ) async throws -> BackupEnvelope {
        let context = container.newBackgroundContext()
        context.undoManager = nil

        let body: BackupData = try await context.perform {
            _ = try FSRSMigrationService.migrateAll(in: context)
            let words = try context.fetch(WordEntity.fetchRequest()).map {
                BackupWord(
                    id: $0.id,
                    english: $0.english,
                    normalizedEnglish: $0.normalizedEnglish,
                    chinese: $0.chinese,
                    importPosition: $0.importPosition,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }

            let states = try context.fetch(ReviewStateEntity.fetchRequest()).map { state in
                guard let wordID = state.word?.id else {
                    throw BackupError.brokenRelationship("复习状态缺少单词")
                }
                return BackupReviewState(
                    id: state.id,
                    wordID: wordID,
                    direction: state.direction,
                    level: state.level,
                    nextReviewDate: state.nextReviewDate,
                    lastReviewDate: state.lastReviewDate,
                    totalReviews: state.totalReviews,
                    knownCount: state.knownCount,
                    unknownCount: state.unknownCount,
                    consecutiveKnown: state.consecutiveKnown,
                    lapseCount: state.lapseCount,
                    lastResult: state.lastResult,
                    fsrsCardData: state.fsrsCardData,
                    fsrsMigrationVersion: state.fsrsMigrationVersion,
                    createdAt: state.createdAt,
                    updatedAt: state.updatedAt
                )
            }

            let sessions = try context.fetch(StudySessionEntity.fetchRequest()).map {
                BackupStudySession(
                    id: $0.id,
                    mode: $0.mode,
                    startedAt: $0.startedAt,
                    finishedAt: $0.finishedAt,
                    completed: $0.completed,
                    baseTaskCount: $0.baseTaskCount,
                    formalAnswered: $0.formalAnswered,
                    formalKnown: $0.formalKnown,
                    formalUnknown: $0.formalUnknown,
                    retryAnswered: $0.retryAnswered,
                    extraAnswered: $0.extraAnswered,
                    extraKnown: $0.extraKnown,
                    extraUnknown: $0.extraUnknown
                )
            }

            let events = try context.fetch(ReviewEventEntity.fetchRequest()).map { event in
                guard let wordID = event.word?.id else {
                    throw BackupError.brokenRelationship("学习记录缺少单词")
                }
                return BackupReviewEvent(
                    id: event.id,
                    wordID: wordID,
                    reviewStateID: event.reviewState.id,
                    sessionID: event.session.id,
                    reviewedAt: event.reviewedAt,
                    direction: event.direction,
                    result: event.result,
                    practiceMode: event.practiceMode,
                    levelBefore: event.levelBefore,
                    levelAfter: event.levelAfter,
                    isSameSessionRetry: event.isSameSessionRetry,
                    wordEnglishSnapshot: event.wordEnglishSnapshot,
                    wordChineseSnapshot: event.wordChineseSnapshot
                )
            }

            let dictationStates = try context.fetch(DictationStateEntity.fetchRequest()).map { state in
                BackupDictationState(
                    id: state.id, wordID: state.wordID,
                    englishVersion: state.englishVersion,
                    initialCopyCount: state.initialCopyCount,
                    initialCopyStartedAt: state.initialCopyStartedAt,
                    initialCopyCompletedAt: state.initialCopyCompletedAt,
                    fsrsCardData: state.fsrsCardData,
                    nextReviewDate: state.nextReviewDate,
                    formalNotBefore: state.formalNotBefore,
                    lastFormalDay: state.lastFormalDay,
                    totalFormal: state.totalFormal,
                    lastResult: state.lastResult
                )
            }
            let dictationDays = try context.fetch(DictationDayEntity.fetchRequest()).map { day in
                BackupDictationDay(
                    id: day.id, dayKey: day.dayKey, timeZoneID: day.timeZoneID,
                    limit: day.limit, phase: day.phase, tasksData: day.tasksData,
                    createdAt: day.createdAt, updatedAt: day.updatedAt
                )
            }
            let dictationEvents = try context.fetch(DictationEventEntity.fetchRequest()).map { event in
                BackupDictationEvent(
                    id: event.id, wordID: event.wordID, dayID: event.dayID,
                    dayKey: event.dayKey, kind: event.kind, formalKey: event.formalKey,
                    result: event.result,
                    reason: event.reason, recognizedText: event.recognizedText,
                    answerSnapshot: event.answerSnapshot, chineseSnapshot: event.chineseSnapshot,
                    submittedAt: event.submittedAt, remainingSeconds: event.remainingSeconds,
                    round: event.round, fsrsBefore: event.fsrsBefore, fsrsAfter: event.fsrsAfter
                )
            }

            let completionDays = try context.fetch(StudyCompletionDayEntity.fetchRequest()).map {
                try JSONDecoder().decode(StudyCompletionDay.self, from: $0.snapshotData)
            }
            return BackupData(
                words: words.sorted { $0.normalizedEnglish < $1.normalizedEnglish },
                reviewStates: states.sorted { $0.id.uuidString < $1.id.uuidString },
                reviewEvents: events.sorted { $0.reviewedAt < $1.reviewedAt },
                studySessions: sessions.sorted { $0.startedAt < $1.startedAt },
                settings: settings,
                dictationStates: dictationStates.sorted { $0.wordID.uuidString < $1.wordID.uuidString },
                dictationDays: dictationDays.sorted { $0.dayKey < $1.dayKey },
                dictationEvents: dictationEvents.sorted { $0.submittedAt < $1.submittedAt },
                completionDays: completionDays.sorted { $0.dayKey < $1.dayKey }
            )
        }

        return BackupEnvelope(
            app: BackupEnvelope.appMarker,
            backupFormatVersion: BackupEnvelope.currentBackupFormatVersion,
            schemaVersion: BackupEnvelope.currentSchemaVersion,
            appVersion: appVersion,
            exportedAt: Date(),
            data: body
        )
    }

    static func encode(_ envelope: BackupEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    static func decodeAndValidate(_ data: Data) throws -> BackupEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(BackupEnvelope.self, from: data)
        try validate(envelope)
        return envelope
    }

    static func validate(_ envelope: BackupEnvelope) throws {
        guard envelope.app == BackupEnvelope.appMarker else { throw BackupError.wrongApp }
        guard envelope.backupFormatVersion == BackupEnvelope.currentBackupFormatVersion else {
            throw BackupError.unsupportedFormat(envelope.backupFormatVersion)
        }
        guard (1...BackupEnvelope.currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw BackupError.unsupportedSchema(envelope.schemaVersion)
        }

        let data = envelope.data
        var completionKeys = Set<String>()
        for day in data.completionDays ?? [] {
            guard completionKeys.insert(day.dayKey).inserted,
                  let zone = TimeZone(identifier: day.timeZoneID) else {
                throw BackupError.invalidData("每日完成记录重复或时区无效")
            }
            if let completedAt = day.completedAt {
                guard day.isComplete,
                      DictationEligibility.dayKey(for: completedAt,
                        calendar: DictationEligibility.calendar(timeZone: zone)) == day.dayKey else {
                    throw BackupError.invalidData("每日完成记录与完成日期不符")
                }
            }
        }
        let wordIDs = Set(data.words.map(\.id))
        guard wordIDs.count == data.words.count else {
            throw BackupError.invalidData("存在重复的单词 ID")
        }
        let normalizedWords = data.words.map(\.normalizedEnglish)
        guard Set(normalizedWords).count == normalizedWords.count,
              data.words.allSatisfy({
                  !$0.normalizedEnglish.isEmpty && !$0.english.isEmpty && !$0.chinese.isEmpty
              }) else {
            throw BackupError.invalidData("单词为空或 normalizedEnglish 重复")
        }

        let stateIDs = Set(data.reviewStates.map(\.id))
        guard stateIDs.count == data.reviewStates.count else {
            throw BackupError.invalidData("存在重复的复习状态 ID")
        }
        var stateKeys = Set<String>()
        for state in data.reviewStates {
            guard wordIDs.contains(state.wordID) else {
                throw BackupError.brokenRelationship("复习状态引用了不存在的单词")
            }
            guard ReviewDirection(rawValue: state.direction) != nil,
                  (0...9).contains(Int(state.level)),
                  state.knownCount >= 0,
                  state.unknownCount >= 0 else {
                throw BackupError.invalidData("复习状态的方向、Level 或计数无效")
            }
            if let cardData = state.fsrsCardData {
                guard (try? SRSScheduler.decodeCard(cardData)) != nil else {
                    throw BackupError.invalidData("复习状态中的调度数据无效")
                }
            }
            let key = "\(state.wordID.uuidString)|\(state.direction)"
            guard stateKeys.insert(key).inserted else {
                throw BackupError.invalidData("同一个单词存在重复方向状态")
            }
        }
        for wordID in wordIDs {
            let directions = Set(
                data.reviewStates
                    .filter { $0.wordID == wordID }
                    .map(\.direction)
            )
            guard directions == Set(ReviewDirection.allCases.map(\.rawValue)) else {
                throw BackupError.invalidData("每个单词必须正好包含两个复习方向")
            }
        }

        let sessionIDs = Set(data.studySessions.map(\.id))
        guard sessionIDs.count == data.studySessions.count,
              data.studySessions.allSatisfy({
                  PracticeMode(rawValue: $0.mode) != nil
                      && $0.baseTaskCount >= 0
                      && $0.formalAnswered >= 0
                      && $0.extraAnswered >= 0
              }) else {
            throw BackupError.invalidData("Session ID、模式或计数无效")
        }

        let eventIDs = Set(data.reviewEvents.map(\.id))
        guard eventIDs.count == data.reviewEvents.count else {
            throw BackupError.invalidData("存在重复的学习记录 ID")
        }
        for event in data.reviewEvents {
            guard wordIDs.contains(event.wordID),
                  stateIDs.contains(event.reviewStateID),
                  sessionIDs.contains(event.sessionID) else {
                throw BackupError.brokenRelationship("学习记录引用了不存在的数据")
            }
            guard ReviewDirection(rawValue: event.direction) != nil,
                  ReviewResult(rawValue: event.result) != nil,
                  PracticeMode(rawValue: event.practiceMode) != nil else {
                throw BackupError.invalidData("学习记录的方向、答案或模式无效")
            }
        }

        if envelope.schemaVersion >= 3 {
            guard data.dictationStates != nil, data.dictationDays != nil,
                  data.dictationEvents != nil else {
                throw BackupError.invalidData("缺少默写学习记录")
            }
        }
        var dictationWordIDs = Set<UUID>()
        for state in data.dictationStates ?? [] {
            guard wordIDs.contains(state.wordID),
                  dictationWordIDs.insert(state.wordID).inserted,
                  (0...3).contains(state.initialCopyCount),
                  state.totalFormal >= 0,
                  !state.englishVersion.isEmpty else {
                throw BackupError.invalidData("默写状态无效")
            }
            if let cardData = state.fsrsCardData,
               (try? SRSScheduler.decodeCard(cardData)) == nil {
                throw BackupError.invalidData("默写调度数据无效")
            }
        }
        var dictationDayKeys = Set<String>()
        for day in data.dictationDays ?? [] {
            guard dictationDayKeys.insert(day.dayKey).inserted,
                  DictationPhase(rawValue: day.phase) != nil,
                  day.limit == 0 || [10, 20, 30, 40, 50].contains(Int(day.limit)),
                  TimeZone(identifier: day.timeZoneID) != nil,
                  let items = try? JSONDecoder().decode([DictationItem].self, from: day.tasksData),
                  Set(items.map(\.wordID)).count == items.count,
                  items.allSatisfy({ wordIDs.contains($0.wordID) }) else {
                throw BackupError.invalidData("默写日队列无效")
            }
        }
        let dictationDayIDs = Set((data.dictationDays ?? []).map(\.id))
        guard dictationDayIDs.count == (data.dictationDays ?? []).count else {
            throw BackupError.invalidData("存在重复的默写日记录 ID")
        }
        var dictationEventIDs = Set<UUID>()
        var formalKeys = Set<String>()
        for event in data.dictationEvents ?? [] {
            guard dictationEventIDs.insert(event.id).inserted,
                  wordIDs.contains(event.wordID),
                  event.dayID.map(dictationDayIDs.contains) ?? true,
                  ["initialCopy", "formal", "baselineFormal", "remediationCopy", "retest",
                   "recognitionRetry", "interruption", "initialCopyKeyboard",
                   "remediationCopyKeyboard", "deferred", "recognitionMismatch", "keyboardVerification"].contains(event.kind),
                  ["correct", "incorrect", "none"].contains(event.result),
                  event.reason.map({ DictationFailureReason(rawValue: $0) != nil }) ?? true,
                  !event.answerSnapshot.isEmpty,
                  event.remainingSeconds.isFinite,
                  (0...(event.kind == "keyboardVerification" ? 60.0 : 30.0)).contains(event.remainingSeconds),
                  event.round >= 0 else {
                throw BackupError.invalidData("默写作答记录无效")
            }
            if event.kind == "formal" || event.kind == "baselineFormal" {
                let expected = "\(event.dayKey)|\(event.wordID.uuidString)"
                guard event.formalKey == expected,
                      formalKeys.insert(expected).inserted else {
                    throw BackupError.invalidData("同一单词同一天存在重复正式默写")
                }
            } else if event.formalKey != nil {
                throw BackupError.invalidData("非正式默写记录带有正式去重标记")
            }
            if let before = event.fsrsBefore,
               (try? SRSScheduler.decodeCard(before)) == nil {
                throw BackupError.invalidData("默写作答前调度数据无效")
            }
            if let after = event.fsrsAfter,
               (try? SRSScheduler.decodeCard(after)) == nil {
                throw BackupError.invalidData("默写作答后调度数据无效")
            }
        }

        guard SessionLimitOption(rawValue: data.settings.sessionLimit) != nil,
              ExtraPracticeScope(rawValue: data.settings.extraPracticeScope) != nil,
              data.settings.dictationLimit.map({ [0, 10, 20, 30, 40, 50].contains($0) }) ?? true,
              (0.30...0.62).contains(data.settings.englishSpeechRate),
              (0.30...0.62).contains(data.settings.chineseSpeechRate) else {
            throw BackupError.invalidData("设置值无效")
        }
        if let campaign = data.settings.baselineCampaign,
           Set(campaign.selectedWordIDs).count != campaign.selectedWordIDs.count {
            throw BackupError.invalidData("旧词摸底名单存在重复词条")
        }
        if let mastered = data.settings.masteredDictationTerms {
            guard Set(mastered).count == mastered.count,
                  mastered.allSatisfy({ !$0.isEmpty && EnglishNormalizer.normalize($0) == $0 }) else {
                throw BackupError.invalidData("已掌握默写词条无效")
            }
        }
    }

    static func restore(
        _ envelope: BackupEnvelope,
        into container: NSPersistentContainer
    ) async throws {
        try validate(envelope)
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil

        try await context.perform {
            do {
                try deleteAll(StudyCompletionDayEntity.fetchRequest(), in: context)
                for item in envelope.data.completionDays ?? [] {
                    let day = StudyCompletionDayEntity(context: context)
                    day.dayKey = item.dayKey
                    day.snapshotData = try JSONEncoder().encode(item)
                }
                try deleteAll(DictationEventEntity.fetchRequest(), in: context)
                try deleteAll(DictationDayEntity.fetchRequest(), in: context)
                try deleteAll(DictationStateEntity.fetchRequest(), in: context)
                try deleteAll(ReviewEventEntity.fetchRequest(), in: context)
                try deleteAll(ReviewStateEntity.fetchRequest(), in: context)
                try deleteAll(StudySessionEntity.fetchRequest(), in: context)
                try deleteAll(WordEntity.fetchRequest(), in: context)

                var words: [UUID: WordEntity] = [:]
                for item in envelope.data.words {
                    let word = WordEntity(context: context)
                    word.id = item.id
                    word.english = item.english
                    word.normalizedEnglish = item.normalizedEnglish
                    word.chinese = item.chinese
                    word.importPosition = item.importPosition ?? 0
                    word.createdAt = item.createdAt
                    word.updatedAt = item.updatedAt
                    words[item.id] = word
                }

                for item in envelope.data.dictationStates ?? [] {
                    guard let word = words[item.wordID] else {
                        throw BackupError.brokenRelationship("恢复默写状态时找不到单词")
                    }
                    let state = DictationStateEntity(context: context)
                    state.id = item.id
                    state.wordID = item.wordID
                    state.word = word
                    state.englishVersion = item.englishVersion
                    state.initialCopyCount = item.initialCopyCount
                    state.initialCopyStartedAt = item.initialCopyStartedAt
                    state.initialCopyCompletedAt = item.initialCopyCompletedAt
                    state.fsrsCardData = item.fsrsCardData
                    state.nextReviewDate = item.nextReviewDate
                    state.formalNotBefore = item.formalNotBefore
                    state.lastFormalDay = item.lastFormalDay
                    state.totalFormal = item.totalFormal
                    state.lastResult = item.lastResult
                }
                for item in envelope.data.dictationDays ?? [] {
                    let day = DictationDayEntity(context: context)
                    day.id = item.id
                    day.dayKey = item.dayKey
                    day.timeZoneID = item.timeZoneID
                    day.limit = item.limit
                    day.phase = item.phase
                    day.tasksData = item.tasksData
                    day.createdAt = item.createdAt
                    day.updatedAt = item.updatedAt
                }
                for item in envelope.data.dictationEvents ?? [] {
                    let event = DictationEventEntity(context: context)
                    event.id = item.id
                    event.wordID = item.wordID
                    event.dayID = item.dayID
                    event.dayKey = item.dayKey
                    event.kind = item.kind
                    event.formalKey = item.formalKey
                    event.result = item.result
                    event.reason = item.reason
                    event.recognizedText = item.recognizedText
                    event.answerSnapshot = item.answerSnapshot
                    event.chineseSnapshot = item.chineseSnapshot
                    event.submittedAt = item.submittedAt
                    event.remainingSeconds = item.remainingSeconds
                    event.round = item.round
                    event.fsrsBefore = item.fsrsBefore
                    event.fsrsAfter = item.fsrsAfter
                }

                var states: [UUID: ReviewStateEntity] = [:]
                for item in envelope.data.reviewStates {
                    guard let word = words[item.wordID] else {
                        throw BackupError.brokenRelationship("恢复复习状态时找不到单词")
                    }
                    let state = ReviewStateEntity(context: context)
                    state.id = item.id
                    state.word = word
                    state.direction = item.direction
                    state.level = item.level
                    state.nextReviewDate = item.nextReviewDate
                    state.lastReviewDate = item.lastReviewDate
                    state.totalReviews = item.totalReviews
                    state.knownCount = item.knownCount
                    state.unknownCount = item.unknownCount
                    state.consecutiveKnown = item.consecutiveKnown
                    state.lapseCount = item.lapseCount
                    state.lastResult = item.lastResult
                    state.fsrsCardData = item.fsrsCardData
                    state.fsrsMigrationVersion = item.fsrsMigrationVersion ?? 0
                    state.createdAt = item.createdAt
                    state.updatedAt = item.updatedAt
                    states[item.id] = state
                }

                var sessions: [UUID: StudySessionEntity] = [:]
                for item in envelope.data.studySessions {
                    let session = StudySessionEntity(context: context)
                    session.id = item.id
                    session.mode = item.mode
                    session.startedAt = item.startedAt
                    session.finishedAt = item.finishedAt
                    session.completed = item.completed
                    session.baseTaskCount = item.baseTaskCount
                    session.formalAnswered = item.formalAnswered
                    session.formalKnown = item.formalKnown
                    session.formalUnknown = item.formalUnknown
                    session.retryAnswered = item.retryAnswered
                    session.extraAnswered = item.extraAnswered
                    session.extraKnown = item.extraKnown
                    session.extraUnknown = item.extraUnknown
                    sessions[item.id] = session
                }

                for item in envelope.data.reviewEvents {
                    guard let word = words[item.wordID],
                          let state = states[item.reviewStateID],
                          let session = sessions[item.sessionID] else {
                        throw BackupError.brokenRelationship("恢复学习记录时找不到关联数据")
                    }
                    let event = ReviewEventEntity(context: context)
                    event.id = item.id
                    event.word = word
                    event.reviewState = state
                    event.session = session
                    event.sessionID = item.sessionID
                    event.reviewedAt = item.reviewedAt
                    event.direction = item.direction
                    event.result = item.result
                    event.practiceMode = item.practiceMode
                    event.levelBefore = item.levelBefore
                    event.levelAfter = item.levelAfter
                    event.isSameSessionRetry = item.isSameSessionRetry
                    event.wordEnglishSnapshot = item.wordEnglishSnapshot
                    event.wordChineseSnapshot = item.wordChineseSnapshot
                }

                _ = try FSRSMigrationService.migrateAll(in: context)

                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private static func deleteAll<T: NSManagedObject>(
        _ request: NSFetchRequest<T>,
        in context: NSManagedObjectContext
    ) throws {
        for object in try context.fetch(request) {
            context.delete(object)
        }
    }
}
