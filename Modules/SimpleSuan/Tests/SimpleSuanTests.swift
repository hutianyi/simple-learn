import XCTest
@testable import SimpleSuan

final class SimpleSuanTests: XCTestCase {
    func testGeneratedQuestionsRespectRules() {
        let generator = QuestionGenerator()
        for operation in OperationType.allCases {
            for _ in 0..<500 {
                let question = generator.makeQuestion(operation)
                XCTAssertTrue((10...99).contains(question.leftOperand))
                switch operation {
                case .addition: XCTAssertTrue((10...99).contains(question.rightOperand)); XCTAssertEqual(question.correctAnswer, question.leftOperand + question.rightOperand)
                case .subtraction: XCTAssertTrue((10...99).contains(question.rightOperand)); XCTAssertGreaterThanOrEqual(question.leftOperand, question.rightOperand); XCTAssertGreaterThanOrEqual(question.correctAnswer, 0)
                case .multiplication: XCTAssertTrue((2...9).contains(question.rightOperand)); XCTAssertEqual(question.correctAnswer, question.leftOperand * question.rightOperand)
                case .division:
                    XCTAssertTrue((2...9).contains(question.rightOperand))
                    XCTAssertTrue((10...49).contains(question.correctAnswer))
                    XCTAssertEqual(question.leftOperand % question.rightOperand, 0)
                    XCTAssertEqual(question.correctAnswer, question.leftOperand / question.rightOperand)
                }
            }
        }
    }
    func testMixedTwentyIsBalancedAndUnique() {
        let questions = QuestionGenerator().generate(mode: .mixed, count: 20)
        XCTAssertEqual(questions.count, 20)
        for operation in OperationType.allCases { XCTAssertEqual(questions.filter { $0.operationType == operation }.count, 5) }
        XCTAssertEqual(Set(questions.map(\.duplicateKey)).count, questions.count)
    }
    func testMixedTenDifferenceIsAtMostOne() {
        let questions = QuestionGenerator().generate(mode: .mixed, count: 10)
        let counts = OperationType.allCases.map { operation in questions.filter { $0.operationType == operation }.count }
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1)
    }
    func testCustomMixedOperationsAreBalancedAndRestricted() {
        let generator = QuestionGenerator()
        let twoTypes = generator.generate(operations: [.addition, .subtraction], count: 10)
        XCTAssertEqual(twoTypes.filter { $0.operationType == .addition }.count, 5)
        XCTAssertEqual(twoTypes.filter { $0.operationType == .subtraction }.count, 5)
        XCTAssertFalse(twoTypes.contains { $0.operationType == .multiplication || $0.operationType == .division })

        let threeTypes = generator.generate(operations: [.subtraction, .multiplication, .division], count: 10)
        let counts = [.subtraction, .multiplication, .division].map { operation in threeTypes.filter { $0.operationType == operation }.count }
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1)
        XCTAssertFalse(threeTypes.contains { $0.operationType == .addition })
    }
    func testStatistics() {
        let records = [record(correct: true, duration: 2), record(correct: false, duration: 6)]
        let stats = StatisticsCalculator.statistics(for: records)
        XCTAssertEqual(stats.correct, 1); XCTAssertEqual(stats.incorrect, 1); XCTAssertEqual(stats.accuracy, 0.5); XCTAssertEqual(stats.totalDuration, 8); XCTAssertEqual(stats.averageDuration, 4); XCTAssertEqual(stats.fastest, 2); XCTAssertEqual(stats.slowest, 6)
    }
    func testAppDataJSONRoundTrip() throws {
        let session = SessionRecord(id: UUID(), startedAt: Date(), completedAt: Date(), practiceMode: .addition, targetQuestionCount: 1, questions: [record(correct: true, duration: 2)])
        let original = AppData(schemaVersion: 1, sessions: [session])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AppData.self, from: data), original)
    }
    func testRemovingOneSessionKeepsOtherHistoryForRecalculation() {
        let first = SessionRecord(id: UUID(), startedAt: Date(), completedAt: Date(), practiceMode: .addition, targetQuestionCount: 1, questions: [record(correct: true, duration: 2)])
        let second = SessionRecord(id: UUID(), startedAt: Date(), completedAt: Date(), practiceMode: .multiplication, targetQuestionCount: 1, questions: [record(correct: false, duration: 6)])
        let remaining = AppData(sessions: [first, second]).removingSession(withID: first.id)
        XCTAssertEqual(remaining.sessions, [second])
        XCTAssertEqual(StatisticsCalculator.statistics(for: remaining.sessions.flatMap(\.questions)).accuracy, 0)
    }
    func testDailyActivityAccumulatesEveryBatchAndCountsWrongAnswers() {
        let now = activityDate(2026, 10, 2, hour: 20)
        let first = activitySession(count: 20, at: now)
        let second = activitySession(count: 40, at: now, operation: .division)
        let activity = PracticeActivity(sessions: [first, second], now: now, calendar: activityCalendar)
        XCTAssertEqual(activity.todayCount, 60)
        XCTAssertEqual(activity.annualPracticeDays, 1)
        XCTAssertEqual(activity.streak, 1)
        let remaining = AppData(sessions: [first, second]).removingSession(withID: second.id)
        XCTAssertEqual(PracticeActivity(sessions: remaining.sessions, now: now, calendar: activityCalendar).todayCount, 20)
        XCTAssertEqual(PracticeActivity(sessions: [], now: now, calendar: activityCalendar).todayCount, 0)
    }

    func testHeatmapDarkensBeyondFortyAndOneHundredQuestions() {
        let counts = [0, 1, 10, 20, 30, 40, 60, 80, 100, 200, 500]
        let intensities = counts.map(PracticeActivity.intensity(for:))
        XCTAssertEqual(intensities.first, 0)
        for pair in zip(intensities, intensities.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
        XCTAssertTrue(intensities.allSatisfy { (0...1).contains($0) })
    }

    func testActivityUsesAnswerDayAcrossLocalMidnight() {
        let yesterday = activityDate(2026, 10, 1, hour: 23)
        let today = activityDate(2026, 10, 2, hour: 1)
        let questions = activitySession(count: 20, at: yesterday).questions
            + activitySession(count: 40, at: today).questions
        let session = SessionRecord(id: UUID(), startedAt: yesterday, completedAt: today,
                                    practiceMode: .mixed, targetQuestionCount: 60, questions: questions)
        let activity = PracticeActivity(sessions: [session], now: today, calendar: activityCalendar)
        XCTAssertEqual(activity.count(on: yesterday), 20)
        XCTAssertEqual(activity.todayCount, 40)
        XCTAssertEqual(activity.streak, 2)
    }

    func testStreakPreservesYesterdayAndStopsAtMissingDay() {
        let now = activityDate(2026, 10, 2)
        let sessions = [1, 0, -1, -3].map { offset in
            activitySession(count: 10, at: activityCalendar.date(byAdding: .day, value: offset, to: now)!)
        }
        XCTAssertEqual(PracticeActivity(sessions: sessions, now: now, calendar: activityCalendar).streak, 2)
        let withoutToday = sessions.filter { !activityCalendar.isDate($0.completedAt, inSameDayAs: now) }
        let pending = PracticeActivity(sessions: withoutToday, now: now, calendar: activityCalendar)
        XCTAssertEqual(pending.todayCount, 0)
        XCTAssertEqual(pending.streak, 1)
        let onlyOlder = sessions.filter { $0.completedAt < activityDate(2026, 10, 1) }
        XCTAssertEqual(PracticeActivity(sessions: onlyOlder, now: now, calendar: activityCalendar).streak, 0)
        XCTAssertEqual(PracticeActivity(sessions: [], now: now, calendar: activityCalendar).streak, 0)
    }

    func testHeatmapCovers365DaysWithMondayRowsAcrossLeapDay() {
        let now = activityDate(2024, 3, 1)
        let firstDay = activityCalendar.date(byAdding: .day, value: -364, to: now)!
        let tooOld = activityCalendar.date(byAdding: .day, value: -1, to: firstDay)!
        let activity = PracticeActivity(sessions: [
            activitySession(count: 10, at: firstDay),
            activitySession(count: 10, at: activityDate(2024, 2, 29)),
            activitySession(count: 10, at: tooOld)
        ], now: now, calendar: activityCalendar)
        let visibleDates = activity.weeks.flatMap { $0 }.filter { $0 >= activity.firstDay && $0 <= activity.today }
        XCTAssertEqual(visibleDates.count, 365)
        XCTAssertEqual(Set(visibleDates).count, 365)
        XCTAssertTrue(visibleDates.contains(activityDate(2024, 2, 29)))
        XCTAssertTrue(activity.weeks.allSatisfy { $0.count == 7 && activityCalendar.component(.weekday, from: $0[0]) == 2 })
        XCTAssertEqual(activity.annualPracticeDays, 2)
    }


    func testRepairRestoresOnlyYesterdayWithoutMovingActualAnswers() throws {
        let now = activityDate(2026, 10, 5, hour: 12)
        let old = activitySession(count: 40, at: activityDate(2026, 10, 3, hour: 12))
        var repair = activitySession(count: 80, at: now)
        repair.repairedDayKey = "2026-10-04"
        let data = try SuanBackup.decode(SuanBackup.encode(AppData(sessions: [old, repair], handledRepairDays: ["2026-10-04"])))
        let activity = PracticeActivity(sessions: data.sessions, now: now, calendar: activityCalendar)
        XCTAssertEqual(activity.streak, 3)
        XCTAssertEqual(activity.todayCount, 80)
        XCTAssertEqual(activity.count(on: activityDate(2026, 10, 4)), 0)
        XCTAssertTrue(activity.isRepaired(activityDate(2026, 10, 4)))
        XCTAssertEqual(activity.annualPracticeDays, 3)
        let deleted = data.removingSession(withID: repair.id)
        XCTAssertEqual(PracticeActivity(sessions: deleted.sessions, now: now, calendar: activityCalendar).streak, 0)
        var invalid = repair
        invalid.repairedDayKey = "2026-10-03"
        XCTAssertThrowsError(try SuanBackup.decode(SuanBackup.encode(AppData(sessions: [invalid]))))
    }

    func testPartialRepairPreservesAnswersButDoesNotRestoreStreak() throws {
        let now = activityDate(2026, 10, 5, hour: 12)
        var partial = activitySession(count: 20, at: now)
        partial = SessionRecord(id: partial.id, startedAt: now, completedAt: now, practiceMode: .mixed,
            targetQuestionCount: 80, questions: partial.questions)
        partial.isPartial = true
        let data = try SuanBackup.decode(SuanBackup.encode(AppData(sessions: [partial])))
        XCTAssertEqual(data.sessions[0].questions.count, 20)
        XCTAssertEqual(PracticeActivity(sessions: data.sessions, now: now, calendar: activityCalendar).streak, 0)
        partial.repairedDayKey = "2026-10-04"
        XCTAssertThrowsError(try SuanBackup.decode(SuanBackup.encode(AppData(sessions: [partial]))))
    }

    @MainActor func testHandledRepairSurvivesRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = PersistenceService(directoryURL: folder)
        let now = Date()
        let prior = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let store = AppDataStore(persistence: persistence)
        try store.add(activitySession(count: 40, at: prior))
        let offer = try XCTUnwrap(store.repairOffer(now: now))
        try store.handleRepair(offer, now: now)
        let relaunched = AppDataStore(persistence: persistence)
        XCTAssertNil(relaunched.repairOffer(now: now))
        XCTAssertThrowsError(try relaunched.handleRepair(offer, now: now))
    }
    private var activityCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func activityDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        activityCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func activitySession(count: Int, at date: Date, operation: OperationType = .addition) -> SessionRecord {
        let questions = (0..<count).map { index in
            QuestionRecord(id: UUID(), sequenceNumber: index + 1, operationType: operation,
                leftOperand: 20, rightOperand: 2, correctAnswer: operation == .division ? 10 : 22,
                userAnswer: 10, isCorrect: operation == .division, durationSeconds: 2,
                presentedAt: date, answeredAt: date)
        }
        return SessionRecord(id: UUID(), startedAt: date, completedAt: date,
            practiceMode: PracticeMode(rawValue: operation.rawValue)!, targetQuestionCount: count, questions: questions)
    }

    private func record(correct: Bool, duration: Double) -> QuestionRecord { QuestionRecord(id: UUID(), sequenceNumber: 1, operationType: .addition, leftOperand: 10, rightOperand: 10, correctAnswer: 20, userAnswer: correct ? 20 : 19, isCorrect: correct, durationSeconds: duration, presentedAt: Date(), answeredAt: Date()) }
}


extension SimpleSuanTests {
    @MainActor
    func testFeedbackAdvancingInBackgroundDoesNotChargeNextQuestion() async throws {
        var uptime = 100.0
        let model = PracticeViewModel(mode: .addition, questionCount: 2, uptime: { uptime })
        defer { model.stop() }
        for digit in String(model.currentQuestion.correctAnswer) { model.append(Int(String(digit))!) }
        uptime = 110
        model.submit()
        model.scenePhaseChanged(isActive: false)
        for _ in 0..<100 where model.index == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.index, 1)
        uptime = 310
        model.scenePhaseChanged(isActive: true)
        uptime = 314
        for digit in String(model.currentQuestion.correctAnswer) { model.append(Int(String(digit))!) }
        model.submit()
        for _ in 0..<100 where model.completedSession == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let session = try XCTUnwrap(model.completedSession)
        XCTAssertEqual(session.questions[0].durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(session.questions[1].durationSeconds, 4, accuracy: 0.001)
    }

    @MainActor
    func testQuestionPausePreservesOnlyForegroundTime() async throws {
        var uptime = 100.0
        let model = PracticeViewModel(mode: .addition, questionCount: 1, uptime: { uptime })
        defer { model.stop() }
        uptime = 105
        model.scenePhaseChanged(isActive: false)
        uptime = 305
        model.scenePhaseChanged(isActive: true)
        uptime = 308
        for digit in String(model.currentQuestion.correctAnswer) { model.append(Int(String(digit))!) }
        model.submit()
        for _ in 0..<100 where model.completedSession == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let session = try XCTUnwrap(model.completedSession)
        XCTAssertEqual(session.questions[0].durationSeconds, 8, accuracy: 0.001)
    }
}
