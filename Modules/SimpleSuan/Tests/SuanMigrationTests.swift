import XCTest
@testable import SimpleSuan

final class SuanMigrationTests: XCTestCase {
    func testCorruptHistoryIsReportedInsteadOfBecomingEmptyHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let corrupt = Data("not-json".utf8)
        let file = folder.appendingPathComponent("data_v1.json")
        try corrupt.write(to: file)
        XCTAssertThrowsError(try PersistenceService(directoryURL: folder).load())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        let persistence = PersistenceService(directoryURL: folder)
        try persistence.save(AppData())
        XCTAssertEqual(try persistence.load(), AppData())
        let preserved = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("CorruptData"), includingPropertiesForKeys: nil)
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), corrupt)
    }

    @MainActor func testRestoreKeepsIDsAndSurvivesRelaunchWithoutDuplicatingSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1700000000)
        let question = QuestionRecord(id: UUID(), sequenceNumber: 1, operationType: .addition,
            leftOperand: 10, rightOperand: 20, correctAnswer: 30, userAnswer: 30, isCorrect: true,
            durationSeconds: 2, presentedAt: now, answeredAt: now.addingTimeInterval(2))
        let session = SessionRecord(id: UUID(), startedAt: now, completedAt: now.addingTimeInterval(2),
            practiceMode: .addition, targetQuestionCount: 1, questions: [question])
        let original = AppData(sessions: [session])
        let store = AppDataStore(persistence: PersistenceService(directoryURL: folder))
        try store.restore(SuanBackup.decode(SuanBackup.encode(original)))
        try store.add(session)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(try PersistenceService(directoryURL: folder).load(), original)
    }
}
