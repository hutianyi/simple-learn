import CoreData
import XCTest
@testable import WordMemoryCards

@MainActor
final class BackupServiceTests: XCTestCase {
    func testRoundTripRestoresAllEntitiesAndRelationships() async throws {
        let source = PersistenceController(inMemory: true)
        let fixture = try seedFixture(in: source.container.viewContext)
        let sourceContext = source.container.viewContext
        let word = try XCTUnwrap(try sourceContext.fetch(WordEntity.fetchRequest()).first)
        let dictation = DictationStateEntity(context: sourceContext)
        dictation.id = UUID()
        dictation.wordID = fixture.wordID
        dictation.word = word
        dictation.englishVersion = "apple"
        dictation.initialCopyCount = 2
        dictation.initialCopyStartedAt = Date()
        dictation.totalFormal = 0
        let day = DictationDayEntity(context: sourceContext)
        day.id = UUID()
        day.dayKey = "2026-09-27"
        day.timeZoneID = "Asia/Shanghai"
        day.limit = 20
        day.phase = DictationPhase.firstPass.rawValue
        day.tasksData = try JSONEncoder().encode([
            DictationItem(wordID: fixture.wordID, english: "apple", chinese: "苹果")
        ])
        day.createdAt = Date()
        day.updatedAt = Date()
        let dictationEvent = DictationEventEntity(context: sourceContext)
        dictationEvent.id = UUID()
        dictationEvent.wordID = fixture.wordID
        dictationEvent.dayID = day.id
        dictationEvent.dayKey = day.dayKey
        dictationEvent.kind = "initialCopy"
        dictationEvent.result = "correct"
        dictationEvent.recognizedText = "apple"
        dictationEvent.answerSnapshot = "apple"
        dictationEvent.chineseSnapshot = "苹果"
        dictationEvent.submittedAt = Date()
        dictationEvent.remainingSeconds = 0
        dictationEvent.round = 0
        try sourceContext.save()
        let settings = BackupSettings(
            sessionLimit: 30,
            englishVoiceIdentifier: nil,
            chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46,
            chineseSpeechRate: 0.46,
            autoSpeakFront: true,
            autoSpeakBack: true,
            hapticsEnabled: true,
            extraPracticeScope: ExtraPracticeScope.weakest20.rawValue,
            baselineCampaign: BaselineCampaignSnapshot(
                selectedWordIDs: [fixture.wordID], activatedAt: Date()
            ),
            masteredDictationTerms: ["apple", "computer"]
        )

        let envelope = try await BackupService.makeEnvelope(
            container: source.container,
            settings: settings,
            appVersion: "1.1"
        )
        let decoded = try BackupService.decodeAndValidate(BackupService.encode(envelope))
        XCTAssertEqual(decoded.data.settings.baselineCampaign?.selectedWordIDs, [fixture.wordID])
        XCTAssertEqual(decoded.data.settings.masteredDictationTerms, ["apple", "computer"])

        let destination = PersistenceController(inMemory: true)
        try await BackupService.restore(decoded, into: destination.container)

        let context = destination.container.viewContext
        let words = try context.fetch(WordEntity.fetchRequest())
        let states = try context.fetch(ReviewStateEntity.fetchRequest())
        let events = try context.fetch(ReviewEventEntity.fetchRequest())
        let sessions = try context.fetch(StudySessionEntity.fetchRequest())
        let dictationStates = try context.fetch(DictationStateEntity.fetchRequest())
        let dictationDays = try context.fetch(DictationDayEntity.fetchRequest())
        let dictationEvents = try context.fetch(DictationEventEntity.fetchRequest())

        XCTAssertEqual(words.map(\.id), [fixture.wordID])
        XCTAssertEqual(words.first?.importPosition, 7)
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.word?.id, fixture.wordID)
        XCTAssertEqual(events.first?.reviewState.id, fixture.stateID)
        XCTAssertEqual(sessions.map(\.id), [fixture.sessionID])
        XCTAssertEqual(dictationStates.first?.initialCopyCount, 2)
        XCTAssertEqual(dictationDays.first?.dayKey, "2026-09-27")
        XCTAssertEqual(dictationDays.first?.timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(dictationDays.first?.tasksData, day.tasksData)
        XCTAssertEqual(dictationEvents.first?.id, dictationEvent.id)
        XCTAssertEqual(dictationEvents.first?.recognizedText, "apple")
        // Compare every serialized field after restore, rather than just record counts.
        let reexported = try await BackupService.makeEnvelope(container: destination.container,
            settings: decoded.data.settings, appVersion: decoded.appVersion)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(reexported.data), try encoder.encode(decoded.data))

    }

    func testSchemaTwoBackupRestoresWithoutInventingDictationProgress() async throws {
        let source = PersistenceController(inMemory: true)
        let fixture = try seedFixture(in: source.container.viewContext)
        let settings = BackupSettings(
            sessionLimit: 30, englishVoiceIdentifier: nil, chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46, chineseSpeechRate: 0.46,
            autoSpeakFront: true, autoSpeakBack: true, hapticsEnabled: true,
            extraPracticeScope: ExtraPracticeScope.weakest20.rawValue
        )
        let current = try await BackupService.makeEnvelope(
            container: source.container, settings: settings, appVersion: "1.1"
        )
        let legacy = BackupEnvelope(
            app: current.app, backupFormatVersion: current.backupFormatVersion,
            schemaVersion: 2, appVersion: current.appVersion, exportedAt: current.exportedAt,
            data: BackupData(
                words: current.data.words, reviewStates: current.data.reviewStates,
                reviewEvents: current.data.reviewEvents, studySessions: current.data.studySessions,
                settings: current.data.settings
            )
        )
        let decoded = try BackupService.decodeAndValidate(BackupService.encode(legacy))
        XCTAssertNil(decoded.data.settings.baselineCampaign)
        XCTAssertNil(decoded.data.settings.masteredDictationTerms)
        let destination = PersistenceController(inMemory: true)
        try await BackupService.restore(decoded, into: destination.container)
        let context = destination.container.viewContext
        XCTAssertEqual(try context.fetch(WordEntity.fetchRequest()).first?.id, fixture.wordID)
        XCTAssertEqual(try context.count(for: DictationStateEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: DictationDayEntity.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: DictationEventEntity.fetchRequest()), 0)
    }

    func testLegacyBackupWordDecodesWithoutImportPosition() throws {
        let word = BackupWord(id: UUID(), english: "apple", normalizedEnglish: "apple",
                              chinese: "苹果", importPosition: 7, createdAt: Date(), updatedAt: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(word)) as? [String: Any])
        json.removeValue(forKey: "importPosition")
        let decoded = try JSONDecoder().decode(BackupWord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.importPosition)
        XCTAssertEqual(decoded.id, word.id)
    }

    func testRejectsWrongAppMarkerBeforeRestore() async throws {
        let controller = PersistenceController(inMemory: true)
        let settings = BackupSettings(
            sessionLimit: 30,
            englishVoiceIdentifier: nil,
            chineseVoiceIdentifier: nil,
            englishSpeechRate: 0.46,
            chineseSpeechRate: 0.46,
            autoSpeakFront: true,
            autoSpeakBack: true,
            hapticsEnabled: true,
            extraPracticeScope: ExtraPracticeScope.weakest20.rawValue
        )
        let valid = try await BackupService.makeEnvelope(
            container: controller.container,
            settings: settings,
            appVersion: "1.1"
        )
        let wrong = BackupEnvelope(
            app: "AnotherApp",
            backupFormatVersion: valid.backupFormatVersion,
            schemaVersion: valid.schemaVersion,
            appVersion: valid.appVersion,
            exportedAt: valid.exportedAt,
            data: valid.data
        )

        XCTAssertThrowsError(try BackupService.validate(wrong))
    }

    private func seedFixture(
        in context: NSManagedObjectContext
    ) throws -> (wordID: UUID, stateID: UUID, sessionID: UUID) {
        let now = Date()
        let word = WordEntity(context: context)
        word.id = UUID()
        word.english = "apple"
        word.normalizedEnglish = "apple"
        word.chinese = "苹果"
        word.importPosition = 7
        word.createdAt = now
        word.updatedAt = now

        var firstState: ReviewStateEntity?
        for direction in ReviewDirection.allCases {
            let state = ReviewStateEntity(context: context)
            state.id = UUID()
            state.word = word
            state.direction = direction.rawValue
            state.level = direction == .englishToChinese ? 2 : 1
            state.nextReviewDate = now
            state.totalReviews = 1
            state.knownCount = 1
            state.unknownCount = 0
            state.consecutiveKnown = 1
            state.lapseCount = 0
            state.lastResult = ReviewResult.known.rawValue
            state.createdAt = now
            state.updatedAt = now
            if firstState == nil { firstState = state }
        }

        let session = StudySessionEntity(context: context)
        session.id = UUID()
        session.mode = PracticeMode.scheduled.rawValue
        session.startedAt = now
        session.finishedAt = now
        session.completed = true
        session.baseTaskCount = 1
        session.formalAnswered = 1
        session.formalKnown = 1

        guard let state = firstState else { throw CocoaError(.validationMissingMandatoryProperty) }
        let event = ReviewEventEntity(context: context)
        event.id = UUID()
        event.word = word
        event.reviewState = state
        event.session = session
        event.sessionID = session.id
        event.reviewedAt = now
        event.direction = state.direction
        event.result = ReviewResult.known.rawValue
        event.practiceMode = PracticeMode.scheduled.rawValue
        event.levelBefore = 1
        event.levelAfter = 2
        event.isSameSessionRetry = false
        event.wordEnglishSnapshot = word.english
        event.wordChineseSnapshot = word.chinese

        try context.save()
        return (word.id, state.id, session.id)
    }
}
