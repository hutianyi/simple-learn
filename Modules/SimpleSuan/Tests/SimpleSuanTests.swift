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
    private func record(correct: Bool, duration: Double) -> QuestionRecord { QuestionRecord(id: UUID(), sequenceNumber: 1, operationType: .addition, leftOperand: 10, rightOperand: 10, correctAnswer: 20, userAnswer: correct ? 20 : 19, isCorrect: correct, durationSeconds: duration, presentedAt: Date(), answeredAt: Date()) }
}
