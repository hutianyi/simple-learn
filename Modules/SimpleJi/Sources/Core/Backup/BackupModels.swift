import Foundation

struct BackupEnvelope: Codable {
    static let appMarker = "WordMemoryCards"
    static let currentBackupFormatVersion = 1
    static let currentSchemaVersion = 4

    let app: String
    let backupFormatVersion: Int
    let schemaVersion: Int
    let appVersion: String
    let exportedAt: Date
    let data: BackupData
}

struct BackupData: Codable {
    let words: [BackupWord]
    let reviewStates: [BackupReviewState]
    let reviewEvents: [BackupReviewEvent]
    let studySessions: [BackupStudySession]
    let settings: BackupSettings
    let dictationStates: [BackupDictationState]?
    let dictationDays: [BackupDictationDay]?
    let dictationEvents: [BackupDictationEvent]?
    let completionDays: [StudyCompletionDay]?

    init(
        words: [BackupWord], reviewStates: [BackupReviewState],
        reviewEvents: [BackupReviewEvent], studySessions: [BackupStudySession],
        settings: BackupSettings,
        dictationStates: [BackupDictationState]? = nil,
        dictationDays: [BackupDictationDay]? = nil,
        dictationEvents: [BackupDictationEvent]? = nil,
        completionDays: [StudyCompletionDay]? = nil
    ) {
        self.words = words
        self.reviewStates = reviewStates
        self.reviewEvents = reviewEvents
        self.studySessions = studySessions
        self.settings = settings
        self.dictationStates = dictationStates
        self.dictationDays = dictationDays
        self.dictationEvents = dictationEvents
        self.completionDays = completionDays
    }
}

struct BackupDictationState: Codable {
    let id: UUID
    let wordID: UUID
    let englishVersion: String
    let initialCopyCount: Int16
    let initialCopyStartedAt: Date
    let initialCopyCompletedAt: Date?
    let fsrsCardData: Data?
    let nextReviewDate: Date?
    let formalNotBefore: Date?
    let lastFormalDay: String?
    let totalFormal: Int64
    let lastResult: String?
}

struct BackupDictationDay: Codable {
    let id: UUID
    let dayKey: String
    let timeZoneID: String
    let limit: Int32
    let phase: String
    let tasksData: Data
    let createdAt: Date
    let updatedAt: Date
}

struct BackupDictationEvent: Codable {
    let id: UUID
    let wordID: UUID
    let dayID: UUID?
    let dayKey: String
    let kind: String
    let formalKey: String?
    let result: String
    let reason: String?
    let recognizedText: String?
    let answerSnapshot: String
    let chineseSnapshot: String
    let submittedAt: Date
    let remainingSeconds: Double
    let round: Int16
    let fsrsBefore: Data?
    let fsrsAfter: Data?
}

struct BackupWord: Codable {
    let id: UUID
    let english: String
    let normalizedEnglish: String
    let chinese: String
    let importPosition: Int64?
    let createdAt: Date
    let updatedAt: Date
}

struct BackupReviewState: Codable {
    let id: UUID
    let wordID: UUID
    let direction: String
    let level: Int16
    let nextReviewDate: Date
    let lastReviewDate: Date?
    let totalReviews: Int64
    let knownCount: Int64
    let unknownCount: Int64
    let consecutiveKnown: Int32
    let lapseCount: Int64
    let lastResult: String?
    let fsrsCardData: Data?
    let fsrsMigrationVersion: Int16?
    let createdAt: Date
    let updatedAt: Date
}

struct BackupReviewEvent: Codable {
    let id: UUID
    let wordID: UUID
    let reviewStateID: UUID
    let sessionID: UUID
    let reviewedAt: Date
    let direction: String
    let result: String
    let practiceMode: String
    let levelBefore: Int16
    let levelAfter: Int16
    let isSameSessionRetry: Bool
    let wordEnglishSnapshot: String
    let wordChineseSnapshot: String
}

struct BackupStudySession: Codable {
    let id: UUID
    let mode: String
    let startedAt: Date
    let finishedAt: Date?
    let completed: Bool
    let baseTaskCount: Int32
    let formalAnswered: Int32
    let formalKnown: Int32
    let formalUnknown: Int32
    let retryAnswered: Int32
    let extraAnswered: Int32
    let extraKnown: Int32
    let extraUnknown: Int32
}

struct BackupSettings: Codable {
    let sessionLimit: Int
    let englishVoiceIdentifier: String?
    let chineseVoiceIdentifier: String?
    let englishSpeechRate: Double
    let chineseSpeechRate: Double
    let autoSpeakFront: Bool
    let autoSpeakBack: Bool
    let hapticsEnabled: Bool
    let extraPracticeScope: String
    let dictationLimit: Int?
    let baselineCampaign: BaselineCampaignSnapshot?
    let masteredDictationTerms: [String]?

    init(
        sessionLimit: Int,
        englishVoiceIdentifier: String?,
        chineseVoiceIdentifier: String?,
        englishSpeechRate: Double,
        chineseSpeechRate: Double,
        autoSpeakFront: Bool,
        autoSpeakBack: Bool,
        hapticsEnabled: Bool,
        extraPracticeScope: String,
        dictationLimit: Int? = nil,
        baselineCampaign: BaselineCampaignSnapshot? = nil,
        masteredDictationTerms: [String]? = nil
    ) {
        self.sessionLimit = sessionLimit
        self.englishVoiceIdentifier = englishVoiceIdentifier
        self.chineseVoiceIdentifier = chineseVoiceIdentifier
        self.englishSpeechRate = englishSpeechRate
        self.chineseSpeechRate = chineseSpeechRate
        self.autoSpeakFront = autoSpeakFront
        self.autoSpeakBack = autoSpeakBack
        self.hapticsEnabled = hapticsEnabled
        self.extraPracticeScope = extraPracticeScope
        self.dictationLimit = dictationLimit
        self.baselineCampaign = baselineCampaign
        self.masteredDictationTerms = masteredDictationTerms
    }
}

struct BackupSummary {
    let exportedAt: Date
    let wordCount: Int
    let stateCount: Int
    let eventCount: Int
    let sessionCount: Int
    let dictationStateCount: Int
    let dictationDayCount: Int
    let dictationEventCount: Int
    let appVersion: String

    init(envelope: BackupEnvelope) {
        exportedAt = envelope.exportedAt
        wordCount = envelope.data.words.count
        stateCount = envelope.data.reviewStates.count
        eventCount = envelope.data.reviewEvents.count
        sessionCount = envelope.data.studySessions.count
        dictationStateCount = envelope.data.dictationStates?.count ?? 0
        dictationDayCount = envelope.data.dictationDays?.count ?? 0
        dictationEventCount = envelope.data.dictationEvents?.count ?? 0
        appVersion = envelope.appVersion
    }

    var confirmationText: String {
        """
        备份日期：\(exportedAt.formatted(date: .abbreviated, time: .shortened))
        单词：\(wordCount)
        双向复习状态：\(stateCount)
        学习记录：\(eventCount)
        Session：\(sessionCount)
        默写词状态：\(dictationStateCount)
        默写日记录：\(dictationDayCount)
        默写作答记录：\(dictationEventCount)
        App 版本：\(appVersion)

        恢复会替换当前本地数据。
        """
    }
}
