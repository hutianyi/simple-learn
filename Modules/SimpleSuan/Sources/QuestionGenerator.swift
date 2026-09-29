import Foundation

struct QuestionGenerator {
    func generate(mode: PracticeMode, count: Int) -> [GeneratedQuestion] {
        let selected = mode.operation.map { [$0] } ?? OperationType.allCases
        return generate(operations: selected, count: count)
    }

    func generate(operations selectedOperations: [OperationType], count: Int) -> [GeneratedQuestion] {
        let available = OperationType.allCases.filter(selectedOperations.contains)
        precondition(!available.isEmpty, "至少需要一种题型")
        let base = count / available.count
        let remainder = count % available.count
        let extras = available.shuffled().prefix(remainder)
        let operations = available.flatMap { operation in
            Array(repeating: operation, count: base + (extras.contains(operation) ? 1 : 0))
        }
        var seen = Set<String>()
        return operations.map { operation in
            var question = makeQuestion(operation)
            var attempts = 0
            while seen.contains(question.duplicateKey) && attempts < 100 {
                question = makeQuestion(operation)
                attempts += 1
            }
            seen.insert(question.duplicateKey)
            return question
        }.shuffled()
    }

    func makeQuestion(_ operation: OperationType) -> GeneratedQuestion {
        switch operation {
        case .addition:
            return GeneratedQuestion(operationType: operation, leftOperand: Int.random(in: 10...99), rightOperand: Int.random(in: 10...99))
        case .subtraction:
            let first = Int.random(in: 10...99), second = Int.random(in: 10...99)
            return GeneratedQuestion(operationType: operation, leftOperand: max(first, second), rightOperand: min(first, second))
        case .multiplication:
            return GeneratedQuestion(operationType: operation, leftOperand: Int.random(in: 10...99), rightOperand: Int.random(in: 2...9))
        case .division:
            let divisor = Int.random(in: 2...9)
            // 除法题必须是两位数被除数 ÷ 一位数，且商也必须是两位数。
            let quotients = (10...49).filter { (10...99).contains($0 * divisor) }
            return GeneratedQuestion(operationType: operation, leftOperand: divisor * quotients.randomElement()!, rightOperand: divisor)
        }
    }
}
