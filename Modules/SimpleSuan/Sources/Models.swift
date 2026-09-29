import Foundation

enum OperationType: String, Codable, CaseIterable, Identifiable {
    case addition, subtraction, multiplication, division
    var id: String { rawValue }
    var title: String { ["addition": "加法", "subtraction": "减法", "multiplication": "乘法", "division": "除法"][rawValue]! }
    var symbol: String { ["addition": "+", "subtraction": "−", "multiplication": "×", "division": "÷"][rawValue]! }
}

enum PracticeMode: String, Codable, CaseIterable, Identifiable {
    case mixed, addition, subtraction, multiplication, division
    var id: String { rawValue }
    var title: String { self == .mixed ? "混合" : OperationType(rawValue: rawValue)!.title }
    var operation: OperationType? { OperationType(rawValue: rawValue) }
}

struct GeneratedQuestion: Identifiable, Equatable {
    let id = UUID()
    let operationType: OperationType
    let leftOperand: Int
    let rightOperand: Int
    var correctAnswer: Int {
        switch operationType {
        case .addition: return leftOperand + rightOperand
        case .subtraction: return leftOperand - rightOperand
        case .multiplication: return leftOperand * rightOperand
        case .division: return leftOperand / rightOperand
        }
    }
    var expression: String { "\(leftOperand) \(operationType.symbol) \(rightOperand)" }
    var duplicateKey: String {
        if operationType == .addition {
            return "addition-\(min(leftOperand, rightOperand))-\(max(leftOperand, rightOperand))"
        }
        return "\(operationType.rawValue)-\(leftOperand)-\(rightOperand)"
    }
}

struct QuestionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let sequenceNumber: Int
    let operationType: OperationType
    let leftOperand: Int
    let rightOperand: Int
    let correctAnswer: Int
    let userAnswer: Int
    let isCorrect: Bool
    let durationSeconds: Double
    let presentedAt: Date
    let answeredAt: Date
    var expression: String { "\(leftOperand) \(operationType.symbol) \(rightOperand)" }
}

struct SessionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let startedAt: Date
    let completedAt: Date
    let practiceMode: PracticeMode
    let selectedOperations: [OperationType]?
    let targetQuestionCount: Int
    let questions: [QuestionRecord]

    init(id: UUID, startedAt: Date, completedAt: Date, practiceMode: PracticeMode,
         selectedOperations: [OperationType]? = nil, targetQuestionCount: Int, questions: [QuestionRecord]) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.practiceMode = practiceMode
        self.selectedOperations = selectedOperations
        self.targetQuestionCount = targetQuestionCount
        self.questions = questions
    }

    var practiceTitle: String {
        guard practiceMode == .mixed, let selectedOperations else { return practiceMode.title }
        let titles = OperationType.allCases.filter(selectedOperations.contains).map(\.title).joined(separator: "、")
        return "混合（\(titles)）"
    }
}

struct AppData: Codable, Equatable {
    var schemaVersion: Int = 1
    var sessions: [SessionRecord] = []

    func removingSession(withID id: UUID) -> AppData {
        var copy = self
        copy.sessions.removeAll { $0.id == id }
        return copy
    }
}
