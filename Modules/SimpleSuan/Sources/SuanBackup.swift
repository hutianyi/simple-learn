import Foundation
import StudyShell

enum SuanBackup {
    static func decode(_ data: Data) throws -> AppData {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(AppData.self, from: data)
        guard value.schemaVersion == 1, Set(value.sessions.map(\.id)).count == value.sessions.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for session in value.sessions {
            guard session.targetQuestionCount > 0,
                  (session.isPartial == true ? session.questions.count > 0 && session.questions.count <= session.targetQuestionCount
                    : session.targetQuestionCount == session.questions.count),
                  session.completedAt >= session.startedAt,
                  Set(session.questions.map(\.id)).count == session.questions.count else { throw CocoaError(.fileReadCorruptFile) }
            for (index, question) in session.questions.enumerated() {
                guard question.sequenceNumber == index + 1, question.durationSeconds.isFinite,
                      question.durationSeconds >= 0, question.isCorrect == (question.userAnswer == question.correctAnswer) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if session.repairedDayKey != nil {
                guard session.validRepairKey() != nil else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        if let handled = value.handledRepairDays {
            guard handled.allSatisfy({ key in
                let parts = key.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3,
                      let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
                return OneDayStreakRepair.dayKey(date) == key
            }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        return value
    }
    static func encode(_ value: AppData) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
